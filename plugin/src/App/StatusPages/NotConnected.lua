local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local BorderedContainer = require(Plugin.App.Components.BorderedContainer)
local Checkbox = require(Plugin.App.Components.Checkbox)
local Header = require(Plugin.App.Components.Header)
local Theme = require(Plugin.App.Theme)
local TextButton = require(Plugin.App.Components.TextButton)
local Tooltip = require(Plugin.App.Components.Tooltip)

local e = Roact.createElement

local HORIZONTAL_PADDING = 12

local function HelperPortEntry(props)
	return e(BorderedContainer, {
		transparency = props.transparency,
		size = UDim2.new(1, 0, 0, 36),
		layoutOrder = props.layoutOrder,
	}, {
		Input = e("TextBox", {
			Text = props.helperPort or "",
			FontFace = props.theme.Font.Code,
			TextSize = props.theme.TextSize.Large,
			TextColor3 = props.theme.AddressEntry.TextColor,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTransparency = props.transparency,
			PlaceholderText = "44750",
			PlaceholderColor3 = props.theme.AddressEntry.PlaceholderColor,
			ClearTextOnFocus = false,

			Size = UDim2.new(1, -HORIZONTAL_PADDING * 2, 1, 0),
			Position = UDim2.new(0, HORIZONTAL_PADDING, 0, 0),
			BackgroundTransparency = 1,

			[Roact.Change.Text] = function(object)
				local text = object.Text:gsub("%D", "")
				object.Text = text
				if props.onHelperPortChange ~= nil then
					props.onHelperPortChange(text)
				end
			end,
		}),
	})
end

local function AutoConnectEntry(props)
	return Theme.with(function(theme)
		return e(BorderedContainer, {
			transparency = props.transparency,
			size = UDim2.new(1, 0, 0, 52),
			layoutOrder = props.layoutOrder,
		}, {
			Label = e("TextLabel", {
				Text = "Auto Connect Once",
				FontFace = theme.Font.Bold,
				TextSize = theme.TextSize.Body,
				TextColor3 = theme.Settings.Setting.NameColor,
				TextTransparency = props.transparency,
				TextXAlignment = Enum.TextXAlignment.Left,
				BackgroundTransparency = 1,
				Position = UDim2.new(0, HORIZONTAL_PADDING, 0, 8),
				Size = UDim2.new(1, -72, 0, 16),
			}),
			Description = e("TextLabel", {
				Text = "Try the helper once when Studio opens. Failures stop until you click Connect again.",
				FontFace = theme.Font.Main,
				TextSize = theme.TextSize.Body,
				TextColor3 = theme.Settings.Setting.DescriptionColor,
				TextTransparency = props.transparency,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				BackgroundTransparency = 1,
				Position = UDim2.new(0, HORIZONTAL_PADDING, 0, 24),
				Size = UDim2.new(1, -72, 0, 20),
			}),
			Toggle = e(Checkbox, {
				active = props.autoConnect,
				transparency = props.transparency,
				position = UDim2.new(1, -40, 0.5, 0),
				anchorPoint = Vector2.new(0, 0.5),
				onClick = function()
					if props.onAutoConnectChange ~= nil then
						props.onAutoConnectChange(not props.autoConnect)
					end
				end,
			}),
		})
	end)
end

local NotConnectedPage = Roact.Component:extend("NotConnectedPage")

function NotConnectedPage:render()
	return Theme.with(function(theme)
		return Roact.createFragment({
			Header = e(Header, {
				transparency = self.props.transparency,
				layoutOrder = 1,
			}),

			HelperPortEntry = e(HelperPortEntry, {
				helperPort = self.props.helperPort,
				onHelperPortChange = self.props.onHelperPortChange,
				transparency = self.props.transparency,
				layoutOrder = 2,
				theme = theme,
			}),

			AutoConnectEntry = e(AutoConnectEntry, {
				autoConnect = self.props.autoConnect,
				onAutoConnectChange = self.props.onAutoConnectChange,
				transparency = self.props.transparency,
				layoutOrder = 3,
			}),

			Buttons = e("Frame", {
				Size = UDim2.new(1, 0, 0, 34),
				LayoutOrder = 4,
				BackgroundTransparency = 1,
				ZIndex = 2,
			}, {
				Settings = e(TextButton, {
					text = "Settings",
					style = "Bordered",
					transparency = self.props.transparency,
					layoutOrder = 1,
					onClick = self.props.onNavigateSettings,
				}, {
					Tip = e(Tooltip.Trigger, {
						text = "View and modify plugin settings",
					}),
				}),

				Connect = e(TextButton, {
					text = "Connect",
					style = "Solid",
					transparency = self.props.transparency,
					layoutOrder = 2,
					onClick = self.props.onConnect,
				}, {
					Tip = e(Tooltip.Trigger, {
						text = "Request the Rojo connection URL from the local helper and connect",
					}),
				}),

				Layout = e("UIListLayout", {
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 10),
				}),
			}),

			Layout = e("UIListLayout", {
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 10),
			}),

			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, 20),
				PaddingRight = UDim.new(0, 20),
			}),
		})
	end)
end

return NotConnectedPage
