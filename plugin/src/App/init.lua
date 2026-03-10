local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)
local Log = require(Packages.Log)
local Promise = require(Packages.Promise)

local Assets = require(Plugin.Assets)
local Version = require(Plugin.Version)
local Config = require(Plugin.Config)
local Settings = require(Plugin.Settings)
local strict = require(Plugin.strict)
local Dictionary = require(Plugin.Dictionary)
local HelperClient = require(Plugin.HelperClient)
local ServeSession = require(Plugin.ServeSession)
local ApiContext = require(Plugin.ApiContext)
local PatchSet = require(Plugin.PatchSet)
local PatchTree = require(Plugin.PatchTree)
local preloadAssets = require(Plugin.preloadAssets)
local soundPlayer = require(Plugin.soundPlayer)
local ignorePlaceIds = require(Plugin.ignorePlaceIds)
local timeUtil = require(Plugin.timeUtil)
local Theme = require(script.Theme)

local Page = require(script.Page)
local Notifications = require(script.Components.Notifications)
local Tooltip = require(script.Components.Tooltip)
local StudioPluginAction = require(script.Components.Studio.StudioPluginAction)
local StudioToolbar = require(script.Components.Studio.StudioToolbar)
local StudioToggleButton = require(script.Components.Studio.StudioToggleButton)
local StudioPluginGui = require(script.Components.Studio.StudioPluginGui)
local StudioPluginContext = require(script.Components.Studio.StudioPluginContext)
local StatusPages = require(script.StatusPages)

local AppStatus = strict("AppStatus", {
	NotConnected = "NotConnected",
	Settings = "Settings",
	Connecting = "Connecting",
	Confirming = "Confirming",
	Connected = "Connected",
	Error = "Error",
})

local e = Roact.createElement

local App = Roact.Component:extend("App")

local AUTO_CONNECT_HELPER_MAX_ATTEMPTS = 4
local AUTO_CONNECT_HELPER_RETRY_DELAY_SECONDS = 2

local function formatRunState()
	return string.format(
		"{isEdit=%s, isRunning=%s, isServer=%s}",
		tostring(RunService:IsEdit()),
		tostring(RunService:IsRunning()),
		tostring(RunService:IsServer())
	)
end

local function waitForSeconds(seconds)
	return Promise.new(function(resolve)
		task.delay(seconds, resolve)
	end)
end

function App:init()
	preloadAssets()

	local priorSyncInfo = self:getPriorSyncInfo()
	self.host, self.setHost = Roact.createBinding(priorSyncInfo.host or "")
	self.port, self.setPort = Roact.createBinding(priorSyncInfo.port or "")
	local savedHelperPort = Settings:get("helperPort") or HelperClient.DEFAULT_HELPER_PORT
	self.helperPort, self.setHelperPort = Roact.createBinding(savedHelperPort)

	self.confirmationBindable = Instance.new("BindableEvent")
	self.confirmationEvent = self.confirmationBindable.Event
	self.knownProjects = {}
	self.notifId = 0
	self.helperTaskId = nil
	self.helperTaskGeneration = nil
	self.helperLaunchId = nil

	self.waypointConnection = ChangeHistoryService.OnUndo:Connect(function(action: string)
		if not string.find(action, "^Rojo: Patch") then
			return
		end

		local undoConnection, redoConnection = nil, nil
		local function cleanup()
			undoConnection:Disconnect()
			redoConnection:Disconnect()
		end

		Log.warn(
			string.format(
				"You've undone '%s'.\nIf this was not intended, please Redo in the topbar or with Ctrl/⌘+Y.",
				action
			)
		)
		local dismissNotif = self:addNotification({
			text = string.format("You've undone '%s'.\nIf this was not intended, please restore.", action),
			timeout = 10,
			onClose = function()
				cleanup()
			end,
			actions = {
				Restore = {
					text = "Restore",
					style = "Solid",
					layoutOrder = 1,
					onClick = function()
						ChangeHistoryService:Redo()
					end,
				},
				Dismiss = {
					text = "Dismiss",
					style = "Bordered",
					layoutOrder = 2,
				},
			},
		})

		undoConnection = ChangeHistoryService.OnUndo:Once(function()
			-- Our notif is now out of date- redoing will not restore the patch
			-- since we've undone even further. Dismiss the notif.
			cleanup()
			dismissNotif()
		end)
		redoConnection = ChangeHistoryService.OnRedo:Once(function(redoneAction: string)
			if redoneAction == action then
				-- The user has restored the patch, so we can dismiss the notif
				cleanup()
				dismissNotif()
			end
		end)
	end)

	self.disconnectUpdatesCheckChanged = Settings:onChanged("checkForUpdates", function()
		self:checkForUpdates()
	end)
	self.disconnectPrereleasesCheckChanged = Settings:onChanged("checkForPrereleases", function()
		self:checkForUpdates()
	end)
	self.disconnectAutoReconnectChanged = Settings:onChanged("autoReconnect", function(value)
		Log.info("Setting autoReconnect changed to {}", tostring(value))
	end)
	self.disconnectHelperAutoConnectChanged = Settings:onChanged("helperAutoConnect", function(value)
		Log.info("Setting helperAutoConnect changed to {}", tostring(value))
	end)

	self:setState({
		appStatus = AppStatus.NotConnected,
		guiEnabled = false,
		helperAutoConnect = Settings:get("helperAutoConnect"),
		confirmData = {},
		patchData = {
			patch = PatchSet.newEmpty(),
			unapplied = PatchSet.newEmpty(),
			timestamp = os.time(),
		},
		notifications = {},
		toolbarIcon = Assets.Images.PluginButton,
	})

	Log.info(
		"Rojo App initialized (runState={}, helperAutoConnect={}, autoReconnect={}, autoConnectPlaytestServer={}, syncReminderMode={}, syncReminderPolling={})",
		formatRunState(),
		tostring(Settings:get("helperAutoConnect")),
		tostring(Settings:get("autoReconnect")),
		tostring(Settings:get("autoConnectPlaytestServer")),
		tostring(Settings:get("syncReminderMode")),
		tostring(Settings:get("syncReminderPolling"))
	)

	self.connectionUrlChangedConnection = workspace:GetAttributeChangedSignal("__Rojo_ConnectionUrl"):Connect(function()
		Log.info(
			"Workspace __Rojo_ConnectionUrl changed to {} (runState={})",
			tostring(workspace:GetAttribute("__Rojo_ConnectionUrl")),
			formatRunState()
		)
	end)
	self.lastObservedRunState = formatRunState()
	self.runStateLogConnection = RunService.Heartbeat:Connect(function()
		local runState = formatRunState()
		if runState ~= self.lastObservedRunState then
			Log.info("Observed run state transition {} -> {}", tostring(self.lastObservedRunState), runState)
			self.lastObservedRunState = runState
		end
	end)

	if RunService:IsEdit() then
		self:checkForUpdates()

		self:startSyncReminderPolling()
		self.disconnectSyncReminderPollingChanged = Settings:onChanged("syncReminderPolling", function(enabled)
			Log.info("Setting syncReminderPolling changed to {}", tostring(enabled))
			if enabled then
				self:startSyncReminderPolling()
			else
				self:stopSyncReminderPolling()
			end
		end)

		if Settings:get("helperAutoConnect") then
			task.defer(function()
				self:startSession("helper_auto_connect")
			end)
		else
			self:tryAutoReconnect():andThen(function(didReconnect)
				if not didReconnect then
					self:checkSyncReminder()
				end
			end)
		end
	end

	if self:isAutoConnectPlaytestServerAvailable() then
		self:useRunningConnectionInfo()
		self:startSession("playtest_server_auto_connect")
	end
	self.autoConnectPlaytestServerListener = Settings:onChanged("autoConnectPlaytestServer", function(enabled)
		Log.info("Setting autoConnectPlaytestServer changed to {}", tostring(enabled))
		if enabled then
			if self:isAutoConnectPlaytestServerWriteable() and self.serveSession ~= nil then
				-- Write the existing session
				local baseUrl = self.serveSession.__apiContext.__baseUrl
				self:setRunningConnectionInfo(baseUrl)
			end
		else
			self:clearRunningConnectionInfo()
		end
	end)
end

function App:willUnmount()
	self:endSession()

	self.waypointConnection:Disconnect()
	self.confirmationBindable:Destroy()

	self.disconnectUpdatesCheckChanged()
	self.disconnectPrereleasesCheckChanged()
	self.disconnectAutoReconnectChanged()
	self.disconnectHelperAutoConnectChanged()
	if self.disconnectSyncReminderPollingChanged then
		self.disconnectSyncReminderPollingChanged()
	end
	if self.connectionUrlChangedConnection then
		self.connectionUrlChangedConnection:Disconnect()
	end
	if self.runStateLogConnection then
		self.runStateLogConnection:Disconnect()
	end

	self:stopSyncReminderPolling()

	self.autoConnectPlaytestServerListener()
	self:clearRunningConnectionInfo()
end

function App:addNotification(notif: {
	text: string,
	isFullscreen: boolean?,
	timeout: number?,
	actions: { [string]: { text: string, style: string, layoutOrder: number, onClick: (any) -> ()? } }?,
	onClose: (any) -> ()?,
})
	if not Settings:get("showNotifications") then
		return
	end

	self.notifId += 1
	local id = self.notifId

	self:setState(function(prevState)
		local notifications = table.clone(prevState.notifications)
		notifications[id] = Dictionary.merge({
			timeout = notif.timeout or 5,
			isFullscreen = notif.isFullscreen or false,
		}, notif)

		return {
			notifications = notifications,
		}
	end)

	return function()
		self:closeNotification(id)
	end
end

function App:closeNotification(id: number)
	if not self.state.notifications[id] then
		return
	end

	self:setState(function(prevState)
		local notifications = table.clone(prevState.notifications)
		notifications[id] = nil

		return {
			notifications = notifications,
		}
	end)
end

function App:checkForUpdates()
	local updateMessage = Version.getUpdateMessage()

	if updateMessage then
		self:addNotification({
			text = updateMessage,
			timeout = 500,
			actions = {
				Dismiss = {
					text = "Dismiss",
					style = "Bordered",
					layoutOrder = 2,
				},
			},
		})
	end
end

function App:getPriorSyncInfo(): { host: string?, port: string?, projectName: string?, timestamp: number? }
	local priorSyncInfos = Settings:get("priorEndpoints")
	if not priorSyncInfos then
		return {}
	end

	local id = if self.helperTaskId ~= nil then tostring(self.helperTaskId) else tostring(game.PlaceId)
	if ignorePlaceIds[id] then
		return {}
	end

	return priorSyncInfos[id] or {}
end

function App:setPriorSyncInfo(host: string, port: string, projectName: string)
	local priorSyncInfos = Settings:get("priorEndpoints")
	if not priorSyncInfos then
		priorSyncInfos = {}
	end

	local now = os.time()

	-- Clear any stale saves to avoid disc bloat
	for placeId, syncInfo in priorSyncInfos do
		if now - (syncInfo.timestamp or now) > 12_960_000 then
			priorSyncInfos[placeId] = nil
			Log.trace("Cleared stale saved endpoint for {}", placeId)
		end
	end

	local id = if self.helperTaskId ~= nil then tostring(self.helperTaskId) else tostring(game.PlaceId)
	if ignorePlaceIds[id] then
		return
	end

	priorSyncInfos[id] = {
		host = if host ~= Config.defaultHost then host else nil,
		port = if port ~= Config.defaultPort then port else nil,
		projectName = projectName,
		timestamp = now,
	}
	Log.trace("Saved last used endpoint for {}", id)

	Settings:set("priorEndpoints", priorSyncInfos)
end

function App:forgetPriorSyncInfo()
	local priorSyncInfos = Settings:get("priorEndpoints")
	if not priorSyncInfos then
		priorSyncInfos = {}
	end

	local id = if self.helperTaskId ~= nil then tostring(self.helperTaskId) else tostring(game.PlaceId)
	priorSyncInfos[id] = nil
	Log.trace("Erased last used endpoint for {}", id)

	Settings:set("priorEndpoints", priorSyncInfos)
end

function App:getHostAndPort()
	local host = self.host:getValue()
	local port = self.port:getValue()

	return if #host > 0 then host else Config.defaultHost, if #port > 0 then port else Config.defaultPort
end

function App:getBaseUrl()
	local host, port = self:getHostAndPort()
	if string.find(host, "^https?://") then
		local normalizedHost = host:gsub("/+$", "")
		if (string.find(normalizedHost, "^https://") and port == "443")
			or (string.find(normalizedHost, "^http://") and port == "80") then
			return normalizedHost
		end

		return string.format("%s:%s", normalizedHost, port)
	end

	return string.format("http://%s:%s", host, port)
end

function App:getSavedConnectionConfig()
	local priorSyncInfo = self:getPriorSyncInfo()
	if priorSyncInfo.host == nil and priorSyncInfo.port == nil then
		return nil
	end

	local host, port = self:getHostAndPort()
	return {
		baseUrl = self:getBaseUrl(),
		host = host,
		port = port,
	}
end

function App:setAndStoreHelperPort(value)
	local normalized = HelperClient.normalizeHelperPort(value)
	self.setHelperPort(normalized)
	Settings:set("helperPort", normalized)
end

function App:setAndStoreHelperAutoConnect(value)
	Settings:set("helperAutoConnect", value)
	self:setState({
		helperAutoConnect = value,
	})
end

function App:getHelperPort()
	return HelperClient.normalizeHelperPort(self.helperPort:getValue())
end

function App:resetHelperBinding()
	self.helperTaskId = nil
	self.helperTaskGeneration = nil
	self.helperLaunchId = nil
end

function App:updateHelperBindingFromConfig(config)
	local taskId = if type(config.taskId) == "string" and config.taskId ~= "" then config.taskId else nil
	local generation = if type(config.generation) == "number" then config.generation else nil
	local launchId = if type(config.launchId) == "string" and config.launchId ~= "" then config.launchId else nil

	if taskId ~= nil and generation ~= nil and launchId ~= nil then
		self.helperTaskId = taskId
		self.helperTaskGeneration = generation
		self.helperLaunchId = launchId
		return
	end

	if taskId ~= nil or generation ~= nil or launchId ~= nil then
		Log.warn(
			"Helper returned partial task binding ({}, {}, {}); clearing cached helper binding.",
			tostring(taskId),
			tostring(generation),
			tostring(launchId)
		)
	end

	self:resetHelperBinding()
end

function App:requestHelperConnectionConfig()
	local helperPort = self:getHelperPort()
	Log.info(
		"Requesting Rojo config from helper on port {} (placeId={}, taskId={}, generation={}, launchId={}, runState={})",
		helperPort,
		tostring(game.PlaceId),
		tostring(self.helperTaskId),
		tostring(self.helperTaskGeneration),
		tostring(self.helperLaunchId),
		formatRunState()
	)
	local request = HelperClient.getRojoConfig(
		helperPort,
		tostring(game.PlaceId),
		self.helperTaskId,
		self.helperTaskGeneration,
		self.helperLaunchId
	)
	if self.helperTaskId ~= nil or self.helperTaskGeneration ~= nil or self.helperLaunchId ~= nil then
		request = request:catch(function(err)
			local staleTaskId = self.helperTaskId
			local staleGeneration = self.helperTaskGeneration
			local staleLaunchId = self.helperLaunchId
			self:resetHelperBinding()
			Log.warn(
				"Helper config lookup for cached task binding ({}, {}, {}) failed: {}. Retrying without cached binding.",
				tostring(staleTaskId),
				tostring(staleGeneration),
				tostring(staleLaunchId),
				tostring(err)
			)
			return HelperClient.getRojoConfig(helperPort, tostring(game.PlaceId), nil, nil, nil)
		end)
	end
	return request:andThen(function(config)
		Log.info(
			"Received Rojo config from helper (baseUrl={}, host={}, port={}, taskId={}, generation={}, launchId={}, authHeaderPresent={})",
			tostring(config.baseUrl),
			tostring(config.host),
			tostring(config.port),
			tostring(config.taskId),
			tostring(config.generation),
			tostring(config.launchId),
			config.authHeader ~= nil and config.authHeader ~= ""
		)
		self:updateHelperBindingFromConfig(config)
		self.setHost(config.host)
		self.setPort(config.port)
		self:setAndStoreHelperPort(helperPort)
		return config
	end)
end

function App:requestHelperConnectionConfigWithRetry(maxAttempts: number, retryDelaySeconds: number, reason: string)
	local attempt = 1

	local function run()
		return self:requestHelperConnectionConfig():catch(function(err)
			if attempt >= maxAttempts then
				return Promise.reject(err)
			end

			Log.warn(
				"Rojo helper config request failed for {} on attempt {}/{}: {}. Retrying in {} seconds",
				tostring(reason),
				tostring(attempt),
				tostring(maxAttempts),
				tostring(err),
				tostring(retryDelaySeconds)
			)
			attempt += 1
			return waitForSeconds(retryDelaySeconds):andThen(run)
		end)
	end

	return run()
end

function App:requestAutoConnectHelperConnection(reason: string)
	return self:requestHelperConnectionConfigWithRetry(
		AUTO_CONNECT_HELPER_MAX_ATTEMPTS,
		AUTO_CONNECT_HELPER_RETRY_DELAY_SECONDS,
		reason
	)
end

function App:isSyncLockAvailable()
	if #Players:GetPlayers() == 0 then
		-- Team Create is not active, so no one can be holding the lock
		return true
	end

	local lock = ServerStorage:FindFirstChild("__Rojo_SessionLock")
	if not lock then
		-- No lock is made yet, so it is available
		return true
	end

	if lock.Value and lock.Value ~= Players.LocalPlayer and lock.Value.Parent then
		-- Someone else is holding the lock
		return false, lock.Value
	end

	-- The lock exists, but is not claimed
	return true
end

function App:claimSyncLock()
	if #Players:GetPlayers() == 0 then
		Log.trace("Skipping sync lock because this isn't in Team Create")
		return true
	end

	local isAvailable, priorOwner = self:isSyncLockAvailable()
	if not isAvailable then
		Log.trace("Skipping sync lock because it is already claimed")
		return false, priorOwner
	end

	local lock = ServerStorage:FindFirstChild("__Rojo_SessionLock")
	if not lock then
		lock = Instance.new("ObjectValue")
		lock.Name = "__Rojo_SessionLock"
		lock.Archivable = false
		lock.Value = Players.LocalPlayer
		lock.Parent = ServerStorage
		Log.trace("Created and claimed sync lock")
		return true
	end

	lock.Value = Players.LocalPlayer
	Log.trace("Claimed existing sync lock")
	return true
end

function App:releaseSyncLock()
	local lock = ServerStorage:FindFirstChild("__Rojo_SessionLock")
	if not lock then
		Log.trace("No sync lock found, assumed released")
		return
	end

	if lock.Value == Players.LocalPlayer then
		lock.Value = nil
		Log.trace("Released sync lock")
		return
	end

	Log.trace("Could not relase sync lock because it is owned by {}", lock.Value)
end

function App:findActiveServer()
	Log.info(
		"Checking for active Rojo server via helper (autoReconnect={}, syncReminderPolling={})",
		tostring(Settings:get("autoReconnect")),
		tostring(Settings:get("syncReminderPolling"))
	)
	return self:requestAutoConnectHelperConnection("active_server_probe"):catch(function(helperErr)
		local savedConnection = self:getSavedConnectionConfig()
		if savedConnection == nil then
			return Promise.reject(helperErr)
		end

		Log.warn(
			"Helper config request failed during active server probe, falling back to saved endpoint {}: {}",
			tostring(savedConnection.baseUrl),
			tostring(helperErr)
		)
		return savedConnection
	end):andThen(function(connection)
		Log.info("Checking for active sync server at {}", connection.baseUrl)
		local apiContext = ApiContext.new(connection.baseUrl, connection.authHeader)
		return apiContext:connect():andThen(function(serverInfo)
			Log.info(
				"Active Rojo server probe succeeded (projectName={}, sessionId={})",
				tostring(serverInfo.projectName),
				tostring(serverInfo.sessionId)
			)
			apiContext:disconnect()
			return serverInfo, connection.host, connection.port
		end)
	end)
end

function App:tryAutoReconnect()
	if not Settings:get("autoReconnect") then
		Log.info("Skipping auto-reconnect because setting is disabled")
		return Promise.resolve(false)
	end

	local priorSyncInfo = self:getPriorSyncInfo()
	if not priorSyncInfo.projectName then
		Log.info("Skipping auto-reconnect because no prior sync info exists for this place")
		return Promise.resolve(false)
	end

	Log.info(
		"Attempting auto-reconnect for prior project {}",
		tostring(priorSyncInfo.projectName)
	)

	return self:findActiveServer()
		:andThen(function(serverInfo)
			if serverInfo.projectName == priorSyncInfo.projectName then
				Log.info("Auto-reconnect found matching server, reconnecting")
				self:addNotification({
					text = `Auto-reconnect discovered project '{serverInfo.projectName}'...`,
				})
				self:startSession("auto_reconnect")
				return true
			end
			Log.info(
				"Auto-reconnect found different server, not reconnecting (priorProject={}, discoveredProject={})",
				tostring(priorSyncInfo.projectName),
				tostring(serverInfo.projectName)
			)
			return false
		end)
		:catch(function(err)
			Log.info("Auto-reconnect did not find a usable server: {}", tostring(err))
			return false
		end)
end

function App:checkSyncReminder()
	local syncReminderMode = Settings:get("syncReminderMode")
	if syncReminderMode == "None" then
		Log.trace("Skipping sync reminder because syncReminderMode is None")
		return
	end

	if self.serveSession ~= nil or not self:isSyncLockAvailable() then
		-- Already syncing or cannot sync, no reason to remind
		Log.trace("Skipping sync reminder because session is active or sync lock is unavailable")
		return
	end

	local priorSyncInfo = self:getPriorSyncInfo()

	self:findActiveServer()
		:andThen(function(serverInfo, host, port)
			Log.info(
				"Sync reminder found active server (projectName={}, host={}, port={})",
				tostring(serverInfo.projectName),
				tostring(host),
				tostring(port)
			)
			self:sendSyncReminder(
				`Project '{serverInfo.projectName}' is serving at {host}:{port}.\nWould you like to connect?`,
				{ "Connect", "Dismiss" }
			)
		end)
		:catch(function(err)
			Log.info("Sync reminder did not find an active server: {}", tostring(err))
			if priorSyncInfo.timestamp and priorSyncInfo.projectName then
				-- We didn't find an active server,
				-- but this place has a prior sync
				-- so we should remind the user to serve

				local timeSinceSync = timeUtil.elapsedToText(os.time() - priorSyncInfo.timestamp)
				self:sendSyncReminder(
					`You synced project '{priorSyncInfo.projectName}' to this place {timeSinceSync}.\nDid you mean to run 'rojo serve' and then connect?`,
					{ "Connect", "Forget", "Dismiss" }
				)
			end
		end)
end

function App:startSyncReminderPolling()
	if
		self.syncReminderPollingThread ~= nil
		or Settings:get("syncReminderMode") == "None"
		or not Settings:get("syncReminderPolling")
	then
		return
	end

	Log.trace("Starting sync reminder polling thread")
	self.syncReminderPollingThread = task.spawn(function()
		while task.wait(30) do
			if self.syncReminderPollingThread == nil then
				-- The polling thread was stopped, so exit
				return
			end
			if self.dismissSyncReminder then
				-- There is already a sync reminder being shown
				task.wait(5)
				continue
			end
			self:checkSyncReminder()
		end
	end)
end

function App:stopSyncReminderPolling()
	if self.syncReminderPollingThread then
		Log.trace("Stopping sync reminder polling thread")
		task.cancel(self.syncReminderPollingThread)
		self.syncReminderPollingThread = nil
	end
end

function App:sendSyncReminder(message: string, shownActions: { string })
	local syncReminderMode = Settings:get("syncReminderMode")
	if syncReminderMode == "None" then
		return
	end

	local connectIndex = table.find(shownActions, "Connect")
	local forgetIndex = table.find(shownActions, "Forget")
	local dismissIndex = table.find(shownActions, "Dismiss")

	self.dismissSyncReminder = self:addNotification({
		text = message,
		timeout = 120,
		isFullscreen = Settings:get("syncReminderMode") == "Fullscreen",
		onClose = function()
			self.dismissSyncReminder = nil
		end,
		actions = {
			Connect = if connectIndex
				then {
					text = "Connect",
					style = "Solid",
					layoutOrder = connectIndex,
					onClick = function()
						self:startSession("sync_reminder")
					end,
				}
				else nil,
			Forget = if forgetIndex
				then {
					text = "Forget",
					style = "Bordered",
					layoutOrder = forgetIndex,
					onClick = function()
						-- The user doesn't want to be reminded again about this sync
						self:forgetPriorSyncInfo()
					end,
				}
				else nil,
			Dismiss = if dismissIndex
				then {
					text = "Dismiss",
					style = "Bordered",
					layoutOrder = dismissIndex,
					onClick = function()
						-- If the user dismisses the reminder,
						-- then we don't need to remind them again
						self:stopSyncReminderPolling()
					end,
				}
				else nil,
		},
	})
end

function App:isAutoConnectPlaytestServerAvailable()
	return RunService:IsRunning()
		and RunService:IsStudio()
		and RunService:IsServer()
		and Settings:get("autoConnectPlaytestServer")
		and workspace:GetAttribute("__Rojo_ConnectionUrl")
end

function App:isAutoConnectPlaytestServerWriteable()
	return RunService:IsEdit() and Settings:get("autoConnectPlaytestServer")
end

function App:setRunningConnectionInfo(baseUrl: string)
	if not self:isAutoConnectPlaytestServerWriteable() then
		Log.info("Skipping setting play solo connection info because current run state is not writeable: {}", formatRunState())
		return
	end

	Log.info("Setting connection info for play solo auto-connect to {}", tostring(baseUrl))
	workspace:SetAttribute("__Rojo_ConnectionUrl", baseUrl)
end

function App:clearRunningConnectionInfo()
	if not RunService:IsEdit() then
		-- Only write connection info from edit mode
		Log.info("Skipping clear of play solo connection info because current run state is not edit: {}", formatRunState())
		return
	end

	Log.info("Clearing connection info for play solo auto-connect")
	workspace:SetAttribute("__Rojo_ConnectionUrl", nil)
end

function App:useRunningConnectionInfo()
	local connectionInfo = workspace:GetAttribute("__Rojo_ConnectionUrl")
	if not connectionInfo then
		Log.info("No playtest server connection info found on workspace attribute")
		return
	end

	Log.info("Using connection info for play solo auto-connect: {}", tostring(connectionInfo))
	local host, port = HelperClient.parseBaseUrl(connectionInfo)

	self.setHost(host)
	self.setPort(port)
end

function App:startSessionWithConnection(connection)
	local host, port = connection.host, connection.port
	local baseUrl = connection.baseUrl
	Log.info(
		"Starting Rojo session with helper-resolved connection (baseUrl={}, host={}, port={}, runState={})",
		tostring(baseUrl),
		tostring(host),
		tostring(port),
		formatRunState()
	)
	local apiContext = ApiContext.new(baseUrl, connection.authHeader)

	local serveSession = ServeSession.new({
		apiContext = apiContext,
		twoWaySync = Settings:get("twoWaySync"),
	})

	serveSession:setUpdateLoadingTextCallback(function(text: string)
		self:setState({
			connectingText = text,
		})
	end)

	self.cleanupPrecommit = serveSession:hookPrecommit(function(patch, instanceMap)
		self:setState({
			patchTree = PatchTree.build(patch, instanceMap, { "Property", "Old", "New" }),
		})
	end)
	self.cleanupPostcommit = serveSession:hookPostcommit(function(patch, instanceMap, unappliedPatch)
		local now = DateTime.now().UnixTimestamp
		self:setState(function(prevState)
			local oldPatchData = prevState.patchData
			local newPatchData = {
				patch = patch,
				unapplied = unappliedPatch,
				timestamp = now,
			}

			if PatchSet.isEmpty(patch) then
				newPatchData.patch = oldPatchData.patch
				newPatchData.unapplied = oldPatchData.unapplied
			elseif now - oldPatchData.timestamp < 2 then
				newPatchData.patch = PatchSet.assign(PatchSet.newEmpty(), oldPatchData.patch, patch)
				newPatchData.unapplied = PatchSet.assign(PatchSet.newEmpty(), oldPatchData.unapplied, unappliedPatch)
			end

			return {
				patchTree = PatchTree.updateMetadata(prevState.patchTree, patch, instanceMap, unappliedPatch),
				patchData = newPatchData,
			}
		end)
	end)

	serveSession:onStatusChanged(function(status, details)
		Log.info(
			"Rojo serve session status changed to {} (details={}, runState={})",
			tostring(status),
			tostring(details),
			formatRunState()
		)
		if status == ServeSession.Status.Connecting then
			if self.dismissSyncReminder then
				self.dismissSyncReminder()
				self.dismissSyncReminder = nil
			end

			self:setState({
				appStatus = AppStatus.Connecting,
				toolbarIcon = Assets.Images.PluginButton,
			})
			self:addNotification({
				text = "Connecting to session...",
			})
		elseif status == ServeSession.Status.Connected then
			self.knownProjects[details] = true
			self:setPriorSyncInfo(host, port, details)
			self:setRunningConnectionInfo(baseUrl)

			local address = ("%s:%s"):format(host, port)
			self:setState({
				appStatus = AppStatus.Connected,
				projectName = details,
				address = address,
				toolbarIcon = Assets.Images.PluginButtonConnected,
			})
			self:addNotification({
				text = string.format("Connected to session '%s' at %s.", details, address),
			})
		elseif status == ServeSession.Status.Disconnected then
			Log.info(
				"Rojo session entered disconnected state (details={}, autoReconnect={}, syncReminderMode={}, syncReminderPolling={})",
				tostring(details),
				tostring(Settings:get("autoReconnect")),
				tostring(Settings:get("syncReminderMode")),
				tostring(Settings:get("syncReminderPolling"))
			)
			self.serveSession = nil
			self:releaseSyncLock()
			self:clearRunningConnectionInfo()
			self:resetHelperBinding()
			self:setState({
				patchData = {
					patch = PatchSet.newEmpty(),
					unapplied = PatchSet.newEmpty(),
					timestamp = os.time(),
				},
			})

			if details ~= nil then
				Log.warn("Disconnected from an error: {}", details)

				self:setState({
					appStatus = AppStatus.Error,
					errorMessage = tostring(details),
					toolbarIcon = Assets.Images.PluginButtonWarning,
				})
				self:addNotification({
					text = tostring(details),
					timeout = 10,
				})
			else
				self:setState({
					appStatus = AppStatus.NotConnected,
					toolbarIcon = Assets.Images.PluginButton,
				})
				self:addNotification({
					text = "Disconnected from session.",
					timeout = 10,
				})
			end
		end
	end)

	serveSession:setConfirmCallback(function(instanceMap, patch, serverInfo)
		if PatchSet.isEmpty(patch) then
			Log.trace("Accepting patch without confirmation because it is empty")
			return "Accept"
		end

		if self:isAutoConnectPlaytestServerAvailable() then
			Log.trace("Accepting patch without confirmation because play solo auto-connect is enabled")
			return "Accept"
		end

		local confirmationBehavior = Settings:get("confirmationBehavior")
		if confirmationBehavior == "Initial" then
			if self.knownProjects[serverInfo.projectName] then
				Log.trace(
					"Accepting patch without confirmation because project has already been connected and behavior is set to Initial"
				)
				return "Accept"
			end
		elseif confirmationBehavior == "Large Changes" then
			if PatchSet.countInstances(patch) < Settings:get("largeChangesConfirmationThreshold") then
				Log.trace(
					"Accepting patch without confirmation because patch is small and behavior is set to Large Changes"
				)
				return "Accept"
			end
		elseif confirmationBehavior == "Unlisted PlaceId" then
			if serverInfo.expectedPlaceIds then
				local isListed = table.find(serverInfo.expectedPlaceIds, tostring(game.PlaceId)) ~= nil
				if isListed then
					Log.trace(
						"Accepting patch without confirmation because placeId is listed and behavior is set to Unlisted PlaceId"
					)
					return "Accept"
				end
			end
		elseif confirmationBehavior == "Never" then
			Log.trace("Accepting patch without confirmation because behavior is set to Never")
			return "Accept"
		end

		if
			PatchSet.hasAdditions(patch) == false
			and PatchSet.hasRemoves(patch) == false
			and PatchSet.containsOnlyInstance(patch, instanceMap, game)
		then
			local datamodelUpdates = PatchSet.getUpdateForInstance(patch, instanceMap, game)
			if
				datamodelUpdates ~= nil
				and next(datamodelUpdates.changedProperties) == nil
				and datamodelUpdates.changedClassName == nil
			then
				Log.trace("Accepting patch without confirmation because it only contains a datamodel name change")
				return "Accept"
			end
		end

		self:setState({
			connectingText = "Computing diff view...",
		})
		self:setState({
			appStatus = AppStatus.Confirming,
			patchTree = PatchTree.build(patch, instanceMap, { "Property", "Current", "Incoming" }),
			confirmData = {
				serverInfo = serverInfo,
			},
			toolbarIcon = Assets.Images.PluginButton,
		})

		self:addNotification({
			text = string.format(
				"Please accept%sor abort the initializing sync session.",
				Settings:get("twoWaySync") and ", reject, " or " "
			),
			timeout = 7,
		})

		return self.confirmationEvent:Wait()
	end)

	serveSession:start()

	self.serveSession = serveSession
end

function App:startSession(source)
	source = source or "manual"
	Log.info(
		"Rojo startSession requested (source={}, runState={}, helperPort={}, helperAutoConnect={}, autoReconnect={}, autoConnectPlaytestServer={})",
		tostring(source),
		formatRunState(),
		tostring(Settings:get("helperPort")),
		tostring(Settings:get("helperAutoConnect")),
		tostring(Settings:get("autoReconnect")),
		tostring(Settings:get("autoConnectPlaytestServer"))
	)
	local claimedLock, priorOwner = self:claimSyncLock()
	if not claimedLock then
		local msg = string.format("Could not sync because user '%s' is already syncing", tostring(priorOwner))

		Log.warn(msg)
		self:addNotification({
			text = msg,
			timeout = 10,
		})
		self:setState({
			appStatus = AppStatus.Error,
			errorMessage = msg,
			toolbarIcon = Assets.Images.PluginButtonWarning,
		})

		return
	end

	self:setState({
		appStatus = AppStatus.Connecting,
		connectingText = "Requesting connection info from helper...",
		toolbarIcon = Assets.Images.PluginButton,
	})

	local requestConnection = self.requestHelperConnectionConfig
	if source == "helper_auto_connect" or source == "auto_reconnect" then
		requestConnection = self.requestAutoConnectHelperConnection
	end

	requestConnection(self, source)
		:andThen(function(connection)
			Log.info("Rojo startSession source {} obtained helper connection, starting serve session", tostring(source))
			self:startSessionWithConnection(connection)
		end)
		:catch(function(err)
			Log.warn("Rojo startSession source {} failed before serve session start: {}", tostring(source), tostring(err))
			self:releaseSyncLock()
			self:setState({
				appStatus = AppStatus.Error,
				errorMessage = tostring(err),
				toolbarIcon = Assets.Images.PluginButtonWarning,
			})
			self:addNotification({
				text = tostring(err),
				timeout = 10,
			})
		end)
end

function App:endSession()
	if self.serveSession == nil then
		return
	end

	Log.info(
		"Disconnecting Rojo session by user action (runState={})",
		formatRunState()
	)

	self.serveSession:stop()
	self.serveSession = nil
	self:resetHelperBinding()
	self:setState({
		appStatus = AppStatus.NotConnected,
	})

	if self.cleanupPrecommit ~= nil then
		self.cleanupPrecommit()
	end
	if self.cleanupPostcommit ~= nil then
		self.cleanupPostcommit()
	end

	Log.trace("Session terminated by user")
end

function App:render()
	local pluginName = "Rojo " .. Version.display(Config.version)

	local function createPageElement(appStatus, additionalProps)
		additionalProps = additionalProps or {}

		local props = Dictionary.merge(additionalProps, {
			component = StatusPages[appStatus],
			active = self.state.appStatus == appStatus,
		})

		return e(Page, props)
	end

	return e(StudioPluginContext.Provider, {
		value = self.props.plugin,
	}, {
		e(Theme.StudioProvider, nil, {
			tooltip = e(Tooltip.Provider, nil, {
				gui = e(StudioPluginGui, {
					id = pluginName,
					title = pluginName,
					active = self.state.guiEnabled,
					isEphemeral = false,

					initDockState = Enum.InitialDockState.Right,
					overridePreviousState = false,
					floatingSize = Vector2.new(320, 210),
					minimumSize = Vector2.new(300, 210),

					zIndexBehavior = Enum.ZIndexBehavior.Sibling,

					onInitialState = function(initialState)
						self:setState({
							guiEnabled = initialState,
						})
					end,

					onClose = function()
						self:setState({
							guiEnabled = false,
						})
					end,
				}, {
					Tooltips = e(Tooltip.Container, nil),

					NotConnectedPage = createPageElement(AppStatus.NotConnected, {
						helperPort = self.helperPort,
						onHelperPortChange = function(value)
							self:setAndStoreHelperPort(value)
						end,
						autoConnect = self.state.helperAutoConnect,
						onAutoConnectChange = function(value)
							self:setAndStoreHelperAutoConnect(value)
						end,

						onConnect = function()
							self:startSession("ui_connect_button")
						end,

						onNavigateSettings = function()
							self.backPage = AppStatus.NotConnected
							self:setState({
								appStatus = AppStatus.Settings,
							})
						end,
					}),

					ConfirmingPage = createPageElement(AppStatus.Confirming, {
						confirmData = self.state.confirmData,
						patchTree = self.state.patchTree,
						createPopup = not self.state.guiEnabled,

						onAbort = function()
							self.confirmationBindable:Fire("Abort")
						end,
						onAccept = function()
							self.confirmationBindable:Fire("Accept")
						end,
						onReject = function()
							self.confirmationBindable:Fire("Reject")
						end,
					}),

					Connecting = createPageElement(AppStatus.Connecting, {
						text = self.state.connectingText,
					}),

					Connected = createPageElement(AppStatus.Connected, {
						projectName = self.state.projectName,
						address = self.state.address,
						patchTree = self.state.patchTree,
						patchData = self.state.patchData,
						serveSession = self.serveSession,

						onDisconnect = function()
							self:endSession()
						end,

						onNavigateSettings = function()
							self.backPage = AppStatus.Connected
							self:setState({
								appStatus = AppStatus.Settings,
							})
						end,
					}),

					Settings = createPageElement(AppStatus.Settings, {
						syncActive = self.serveSession ~= nil
							and self.serveSession:getStatus() == ServeSession.Status.Connected,

						onBack = function()
							self:setState({
								appStatus = self.backPage or AppStatus.NotConnected,
							})
						end,
					}),

					Error = createPageElement(AppStatus.Error, {
						errorMessage = self.state.errorMessage,

						onClose = function()
							self:setState({
								appStatus = AppStatus.NotConnected,
								toolbarIcon = Assets.Images.PluginButton,
							})
						end,
					}),
				}),

				RojoNotifications = e("ScreenGui", {
					ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
					ResetOnSpawn = false,
					DisplayOrder = 100,
				}, {
					Notifications = e(Notifications, {
						soundPlayer = self.props.soundPlayer,
						notifications = self.state.notifications,
						onClose = function(id)
							self:closeNotification(id)
						end,
					}),
				}),
			}),

			toggleAction = e(StudioPluginAction, {
				name = "RojoConnection",
				title = "Rojo: Connect/Disconnect",
				description = "Toggles the server for a Rojo sync session",
				icon = Assets.Images.PluginButton,
				bindable = true,
				onTriggered = function()
					if self.serveSession == nil or self.serveSession:getStatus() == ServeSession.Status.NotStarted then
						self:startSession("toolbar_toggle")
					elseif
						self.serveSession ~= nil and self.serveSession:getStatus() == ServeSession.Status.Connected
					then
						self:endSession()
					end
				end,
			}),

			connectAction = e(StudioPluginAction, {
				name = "RojoConnect",
				title = "Rojo: Connect",
				description = "Connects the server for a Rojo sync session",
				icon = Assets.Images.PluginButton,
				bindable = true,
				onTriggered = function()
					if self.serveSession == nil or self.serveSession:getStatus() == ServeSession.Status.NotStarted then
						self:startSession("action_connect")
					end
				end,
			}),

			disconnectAction = e(StudioPluginAction, {
				name = "RojoDisconnect",
				title = "Rojo: Disconnect",
				description = "Disconnects the server for a Rojo sync session",
				icon = Assets.Images.PluginButton,
				bindable = true,
				onTriggered = function()
					if self.serveSession ~= nil and self.serveSession:getStatus() == ServeSession.Status.Connected then
						self:endSession()
					end
				end,
			}),

			toolbar = e(StudioToolbar, {
				name = pluginName,
			}, {
				button = e(StudioToggleButton, {
					name = "Rojo",
					tooltip = "Show or hide the Rojo panel",
					icon = self.state.toolbarIcon,
					active = self.state.guiEnabled,
					enabled = true,
					onClick = function()
						self:setState(function(state)
							return {
								guiEnabled = not state.guiEnabled,
							}
						end)
					end,
				}),
			}),
		}),
	})
end

return function(props)
	local mergedProps = Dictionary.merge(props, {
		soundPlayer = soundPlayer.new(Settings),
	})

	return e(App, mergedProps)
end
