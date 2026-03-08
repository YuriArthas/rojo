local Packages = script.Parent.Parent.Packages
local HttpService = game:GetService("HttpService")
local Http = require(Packages.Http)
local Log = require(Packages.Log)
local Promise = require(Packages.Promise)

local Config = require(script.Parent.Config)
local Types = require(script.Parent.Types)
local Version = require(script.Parent.Version)

local validateApiInfo = Types.ifEnabled(Types.ApiInfoResponse)
local validateApiRead = Types.ifEnabled(Types.ApiReadResponse)
local validateApiSocketPacket = Types.ifEnabled(Types.ApiSocketPacket)
local validateApiSerialize = Types.ifEnabled(Types.ApiSerializeResponse)
local validateApiRefPatch = Types.ifEnabled(Types.ApiRefPatchResponse)

local function normalizeAuthHeader(authHeader)
	if type(authHeader) ~= "string" then
		return nil
	end

	local trimmed = authHeader:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then
		return nil
	end

	if string.find(trimmed, "%s") then
		return trimmed
	end

	return "Bearer " .. trimmed
end

local function containsPlaceId(placeIds, placeId)
	local target = tostring(placeId)

	for _, listedId in ipairs(placeIds) do
		if tostring(listedId) == target then
			return true
		end
	end

	return false
end

local function rejectFailedRequests(response)
	if response.code >= 400 then
		local message = string.format("HTTP %s:\n%s", tostring(response.code), response.body)

		return Promise.reject(message)
	end

	return response
end

local function rejectWrongProtocolVersion(infoResponseBody)
	if infoResponseBody.protocolVersion ~= Config.protocolVersion then
		local message = (
			"Found a Rojo dev server, but it's using a different protocol version, and is incompatible."
			.. "\nMake sure you have matching versions of both the Rojo plugin and server!"
			.. "\n\nYour client is version %s, with protocol version %s. It expects server version %s."
			.. "\nYour server is version %s, with protocol version %s."
			.. "\n\nGo to https://github.com/rojo-rbx/rojo for more details."
		):format(
			Version.display(Config.version),
			Config.protocolVersion,
			Config.expectedServerVersionString,
			infoResponseBody.serverVersion,
			infoResponseBody.protocolVersion
		)

		return Promise.reject(message)
	end

	return Promise.resolve(infoResponseBody)
end

local function rejectWrongPlaceId(infoResponseBody)
	if infoResponseBody.expectedPlaceIds ~= nil then
		local foundId = containsPlaceId(infoResponseBody.expectedPlaceIds, game.PlaceId)

		if not foundId then
			local idList = {}
			for _, id in ipairs(infoResponseBody.expectedPlaceIds) do
				table.insert(idList, "- " .. tostring(id))
			end

			local message = (
				"Found a Rojo server, but its project is set to only be used with a specific list of places."
				.. "\nYour place ID is %u, but needs to be one of these:"
				.. "\n%s"
				.. "\n\nTo change this list, edit 'servePlaceIds' in your .project.json file."
			):format(game.PlaceId, table.concat(idList, "\n"))

			return Promise.reject(message)
		end
	end

	if infoResponseBody.unexpectedPlaceIds ~= nil then
		local foundId = containsPlaceId(infoResponseBody.unexpectedPlaceIds, game.PlaceId)

		if foundId then
			local idList = {}
			for _, id in ipairs(infoResponseBody.unexpectedPlaceIds) do
				table.insert(idList, "- " .. tostring(id))
			end

			local message = (
				"Found a Rojo server, but its project is set to not be used with a specific list of places."
				.. "\nYour place ID is %u, but needs to not be one of these:"
				.. "\n%s"
				.. "\n\nTo change this list, edit 'blockedPlaceIds' in your .project.json file."
			):format(game.PlaceId, table.concat(idList, "\n"))

			return Promise.reject(message)
		end
	end

	return Promise.resolve(infoResponseBody)
end

local ApiContext = {}
ApiContext.__index = ApiContext

local function nowSeconds()
	return os.clock()
end

local function formatAgeSeconds(timestamp)
	if timestamp == nil then
		return "n/a"
	end

	return string.format("%.2f", nowSeconds() - timestamp)
end

function ApiContext.new(baseUrl, authHeader)
	assert(type(baseUrl) == "string", "baseUrl must be a string")
	local normalizedAuthHeader = normalizeAuthHeader(authHeader)
	local requestHeaders = nil
	if normalizedAuthHeader ~= nil then
		requestHeaders = {
			Authorization = normalizedAuthHeader,
		}
	end

	local self = {
		__baseUrl = baseUrl,
		__requestHeaders = requestHeaders,
		__sessionId = nil,
		__messageCursor = -1,
		__wsClient = nil,
		__connected = true,
		__activeRequests = {},
		__wsUrl = nil,
		__wsConnectedAt = nil,
		__wsLastMessageAt = nil,
		__wsMessageCount = 0,
	}

	return setmetatable(self, ApiContext)
end

function ApiContext:__fmtDebug(output)
	output:writeLine("ApiContext {{")
	output:indent()

	output:writeLine("Connected: {}", self.__connected)
	output:writeLine("Base URL: {}", self.__baseUrl)
	output:writeLine("Session ID: {}", self.__sessionId)
	output:writeLine("Message Cursor: {}", self.__messageCursor)

	output:unindent()
	output:write("}")
end

function ApiContext:disconnect()
	self.__connected = false
	if self.__wsClient ~= nil then
		Log.info(
			"Disconnecting Rojo websocket (sessionId={}, messageCursor={}, messageCount={}, idleSeconds={})",
			tostring(self.__sessionId),
			tostring(self.__messageCursor),
			tostring(self.__wsMessageCount),
			formatAgeSeconds(self.__wsLastMessageAt)
		)
	end
	for request in self.__activeRequests do
		Log.trace("Cancelling request {}", request)
		request:cancel()
	end
	self.__activeRequests = {}

	if self.__wsClient then
		Log.trace("Closing WebSocket client")
		self.__wsClient:Close()
	end
	self.__wsClient = nil
end

function ApiContext:setMessageCursor(index)
	self.__messageCursor = index
end

function ApiContext:get(url)
	return Http.get(url, self.__requestHeaders)
end

function ApiContext:post(url, body)
	return Http.post(url, body, self.__requestHeaders)
end

function ApiContext:connect()
	local url = ("%s/api/rojo"):format(self.__baseUrl)
	Log.info(
		"Connecting Rojo API context to {} (authHeaderPresent={})",
		url,
		self.__requestHeaders ~= nil
	)

	return self:get(url)
		:andThen(rejectFailedRequests)
		:andThen(Http.Response.msgpack)
		:andThen(rejectWrongProtocolVersion)
		:andThen(function(body)
			assert(validateApiInfo(body))

			return body
		end)
		:andThen(rejectWrongPlaceId)
		:andThen(function(body)
			self.__sessionId = body.sessionId
			local expectedPlaceIdCount = "nil"
			if body.expectedPlaceIds ~= nil then
				expectedPlaceIdCount = tostring(#body.expectedPlaceIds)
			end
			Log.info(
				"Connected Rojo API context to {} (sessionId={}, projectName={}, expectedPlaceIds={})",
				self.__baseUrl,
				tostring(body.sessionId),
				tostring(body.projectName),
				expectedPlaceIdCount
			)

			return body
		end)
end

function ApiContext:read(ids)
	local url = ("%s/api/read/%s"):format(self.__baseUrl, table.concat(ids, ","))

	return self:get(url):andThen(rejectFailedRequests):andThen(Http.Response.msgpack):andThen(function(body)
		if body.sessionId ~= self.__sessionId then
			return Promise.reject("Server changed ID")
		end

		assert(validateApiRead(body))

		return body
	end)
end

function ApiContext:write(patch)
	local url = ("%s/api/write"):format(self.__baseUrl)

	local updated = {}
	for _, update in ipairs(patch.updated) do
		local fixedUpdate = {
			id = update.id,
			changedName = update.changedName,
		}

		if next(update.changedProperties) ~= nil then
			fixedUpdate.changedProperties = update.changedProperties
		end

		table.insert(updated, fixedUpdate)
	end

	-- Only add the 'added' field if the table is non-empty, or else the msgpack
	-- encode implementation will turn the table into an array instead of a map,
	-- causing API validation to fail.
	local added
	if next(patch.added) ~= nil then
		added = patch.added
	end

	local body = {
		sessionId = self.__sessionId,
		removed = patch.removed,
		updated = updated,
		added = added,
	}

	body = Http.msgpackEncode(body)

	return self:post(url, body)
		:andThen(rejectFailedRequests)
		:andThen(Http.Response.msgpack)
		:andThen(function(responseBody)
			Log.info("Write response: {:?}", responseBody)

			return responseBody
		end)
end

function ApiContext:connectWebSocket(packetHandlers)
	local url = ("%s/api/socket/%s"):format(self.__baseUrl, self.__messageCursor)
	-- Convert HTTP/HTTPS URL to WS/WSS
	url = url:gsub("^http://", "ws://"):gsub("^https://", "wss://")
	Log.info(
		"Connecting Rojo websocket to {} (sessionId={}, cursor={}, authHeaderPresent={})",
		url,
		self.__sessionId,
		self.__messageCursor,
		self.__requestHeaders ~= nil
	)

	return Promise.new(function(resolve, reject)
		local options = {
			Url = url,
		}

		if self.__requestHeaders ~= nil then
			options.Headers = self.__requestHeaders
		end

		local success, wsClient =
			pcall(HttpService.CreateWebStreamClient, HttpService, Enum.WebStreamClientType.WebSocket, options)
		if not success then
			Log.error("Failed to create Rojo websocket client for {}: {}", url, tostring(wsClient))
			reject("Failed to create WebSocket client: " .. tostring(wsClient))
			return
		end
		self.__wsClient = wsClient
		self.__wsUrl = url
		self.__wsConnectedAt = nowSeconds()
		self.__wsLastMessageAt = nowSeconds()
		self.__wsMessageCount = 0
		Log.info(
			"Created Rojo websocket client for {} (sessionId={}, cursor={}, headers={})",
			url,
			tostring(self.__sessionId),
			tostring(self.__messageCursor),
			self.__requestHeaders ~= nil
		)

		local closed, errored, received
		Log.info("Attaching Rojo websocket event listeners for {}", url)

		received = self.__wsClient.MessageReceived:Connect(function(msg)
			self.__wsLastMessageAt = nowSeconds()
			self.__wsMessageCount = self.__wsMessageCount + 1
			if self.__wsMessageCount == 1 then
				Log.info(
					"Rojo websocket received first message for {} after {} seconds",
					url,
					formatAgeSeconds(self.__wsConnectedAt)
				)
			end
			local data = Http.msgpackDecode(msg)
			if data.sessionId ~= self.__sessionId then
				Log.warn("Received message with wrong session ID; ignoring")
				return
			end

			assert(validateApiSocketPacket(data))

			Log.trace("Received websocket packet: {:#?}", data)

			local handler = packetHandlers[data.packetType]
			if handler then
				local ok, err = pcall(handler, data.body)
				if not ok then
					Log.error("Error in WebSocket packet handler for type '%s': %s", data.packetType, err)
				end
			else
				Log.warn("No handler for WebSocket packet type '%s'", data.packetType)
			end
		end)

		closed = self.__wsClient.Closed:Connect(function()
			Log.warn(
				"Rojo websocket closed for {} (connected={}, sessionId={}, messageCount={}, idleSeconds={}, lifetimeSeconds={})",
				url,
				self.__connected,
				tostring(self.__sessionId),
				self.__wsMessageCount,
				formatAgeSeconds(self.__wsLastMessageAt),
				formatAgeSeconds(self.__wsConnectedAt)
			)
			closed:Disconnect()
			errored:Disconnect()
			received:Disconnect()

			if self.__connected then
				Log.warn("Rejecting Rojo websocket promise because connection closed while context is still connected")
				reject("WebSocket connection closed unexpectedly")
			else
				Log.info("Resolving Rojo websocket promise after intentional disconnect")
				resolve()
			end
		end)

		errored = self.__wsClient.Error:Connect(function(code, msg)
			Log.error(
				"Rojo websocket errored for {}: {} - {} (sessionId={}, messageCount={}, idleSeconds={}, lifetimeSeconds={})",
				url,
				tostring(code),
				tostring(msg),
				tostring(self.__sessionId),
				self.__wsMessageCount,
				formatAgeSeconds(self.__wsLastMessageAt),
				formatAgeSeconds(self.__wsConnectedAt)
			)
			closed:Disconnect()
			errored:Disconnect()
			received:Disconnect()

			Log.warn("Rejecting Rojo websocket promise because websocket emitted error event")
			reject("WebSocket error: " .. code .. " - " .. msg)
		end)
	end)
end

function ApiContext:open(id)
	local url = ("%s/api/open/%s"):format(self.__baseUrl, id)

	return self:post(url, ""):andThen(rejectFailedRequests):andThen(Http.Response.msgpack):andThen(function(body)
		if body.sessionId ~= self.__sessionId then
			return Promise.reject("Server changed ID")
		end

		return nil
	end)
end

function ApiContext:serialize(ids: { string })
	local url = ("%s/api/serialize"):format(self.__baseUrl)
	local request_body = Http.msgpackEncode({ sessionId = self.__sessionId, ids = ids })

	return self:post(url, request_body)
		:andThen(rejectFailedRequests)
		:andThen(Http.Response.msgpack)
		:andThen(function(response_body)
			if response_body.sessionId ~= self.__sessionId then
				return Promise.reject("Server changed ID")
			end

			assert(validateApiSerialize(response_body))

			return response_body
		end)
end

function ApiContext:refPatch(ids: { string })
	local url = ("%s/api/ref-patch"):format(self.__baseUrl)
	local request_body = Http.msgpackEncode({ sessionId = self.__sessionId, ids = ids })

	return self:post(url, request_body)
		:andThen(rejectFailedRequests)
		:andThen(Http.Response.msgpack)
		:andThen(function(response_body)
			if response_body.sessionId ~= self.__sessionId then
				return Promise.reject("Server changed ID")
			end

			assert(validateApiRefPatch(response_body))

			return response_body
		end)
end

return ApiContext
