local HttpService = game:GetService("HttpService")

local Rojo = script:FindFirstAncestor("Rojo")
local Packages = Rojo.Packages

local Log = require(Packages.Log)
local Promise = require(Packages.Promise)

local DEFAULT_HELPER_PORT = "44750"

local function trim(value)
	return tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeHelperPort(value)
	local digits = trim(value):gsub("%D", "")
	if digits == "" then
		return DEFAULT_HELPER_PORT
	end
	return digits
end

local function parseBaseUrl(baseUrl)
	local scheme, authority = string.match(baseUrl, "^(https?)://([^/]+)$")
	if not scheme or not authority then
		error("Helper returned an invalid base_url: " .. tostring(baseUrl))
	end

	local host, port = string.match(authority, "^(.+):(%d+)$")
	if not host then
		host = authority
		if scheme == "https" then
			port = "443"
		else
			port = "80"
		end
	end

	return host, port
end

local function getRojoConfig(helperPort, placeId, taskId)
	local normalizedPort = normalizeHelperPort(helperPort)
	return Promise.new(function(resolve, reject)
		local url = string.format("http://127.0.0.1:%s/v1/rojo/config?placeId=%s", normalizedPort, tostring(placeId))
		if taskId ~= nil and taskId ~= "" then
			url = url .. "&taskId=" .. HttpService:UrlEncode(tostring(taskId))
		end
		local request = {
			Url = url,
			Method = "GET",
		}
		Log.info(
			"Requesting Rojo helper config (helperPort={}, normalizedPort={}, placeId={}, taskId={})",
			tostring(helperPort),
			tostring(normalizedPort),
			tostring(placeId),
			tostring(taskId)
		)

		local ok, response = pcall(function()
			return HttpService:RequestAsync(request)
		end)
		if not ok then
			Log.warn("Rojo helper config request failed before HTTP response: {}", tostring(response))
			return reject("Failed to request helper config: " .. tostring(response))
		end

		if not response.Success then
			Log.warn(
				"Rojo helper config request returned non-success status (statusCode={}, body={})",
				tostring(response.StatusCode),
				trim(response.Body)
			)
			return reject(string.format(
				"Helper returned %d while requesting Rojo config: %s",
				response.StatusCode,
				trim(response.Body)
			))
		end

		local decodeOk, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if not decodeOk then
			Log.warn("Rojo helper config JSON decode failed: {}", tostring(decoded))
			return reject("Failed to decode helper JSON: " .. tostring(decoded))
		end

		if type(decoded) ~= "table" or type(decoded.base_url) ~= "string" then
			Log.warn("Rojo helper config response missing base_url")
			return reject("Helper response did not include a base_url")
		end

		local host, port = parseBaseUrl(decoded.base_url)
		Log.info(
			"Rojo helper config resolved successfully (baseUrl={}, host={}, port={}, authHeaderPresent={})",
			tostring(decoded.base_url),
			tostring(host),
			tostring(port),
			decoded.auth_header ~= nil and tostring(decoded.auth_header) ~= ""
		)
		resolve({
			baseUrl = decoded.base_url,
			authHeader = decoded.auth_header,
			taskId = decoded.task_id,
			host = host,
			port = port,
			helperPort = normalizedPort,
		})
	end)
end

return {
	DEFAULT_HELPER_PORT = DEFAULT_HELPER_PORT,
	normalizeHelperPort = normalizeHelperPort,
	parseBaseUrl = parseBaseUrl,
	getRojoConfig = getRojoConfig,
}
