
local PANEL = {}
local CACHE_PATH = "daddonmap_steamworks_cache.json"

-- preview id caching.
local steamworksCache = {}

local function bytesToMB(bytes)
	return bytes / 1e6
end

--- Load steamworks cache
-- Reads the cached workshop preview IDs from the data folder and rebuilds
-- the in-memory cache table. Filters out entries for addons that are no
-- longer installed, and rewrites the cache file if any stale entries are removed.
local function loadSteamworksCache()

	if (!file.Exists(CACHE_PATH, "DATA")) then return end

	local decoded = util.JSONToTable(file.Read(CACHE_PATH, "DATA"))
	if (!decoded) then return end

	-- build a set of currently installed wsids for fast lookup.
	local installed = {}
	for k, v in ipairs(engine.GetAddons()) do
		installed[tostring(v.wsid)] = true
	end

	local dirty = false
	for wsid, previewid in pairs(decoded) do
		if (installed[tostring(wsid)]) then
			steamworksCache[tostring(wsid)] = previewid
		else
			dirty = true
		end
	end

	-- persist the pruned cache if anything was removed.
	if (dirty) then
		file.Write(CACHE_PATH, util.TableToJSON(steamworksCache))
	end
end

--- Setup
-- Creates the square map renderer and render target.
-- Used for displaying addon content. Also loads the Steamworks cache to
-- ensure workshop preview data is available.
function PANEL:Setup()

	local squaremap   = include("includes/modules/squaremap.lua")
	self.SquareMap    = squaremap.new(1024, 1024)
	self.SquareMapRT  = GetRenderTarget("daddonmap", 1024, 1024)
	self.SquareMapMat = CreateMaterial("daddonmap", "UnlitGeneric", {
		["$basetexture"] = "daddonmap",
		["$translucent"] = 1
	})

	loadSteamworksCache()
end

--- Component initialization
-- Initializes the DAddonMap panel.
function PANEL:Init()

	self:Setup()

	self.Container = vgui.Create("DPanel", self)
	self.Container:Dock(FILL)

	local controls = vgui.Create("DSizeToContents", self.Container)
	controls:SetSizeX(false)
	controls:Dock(TOP)
	controls:DockMargin(5, 0, 5, 5)

	local title = vgui.Create("DLabel", controls)
	title:Dock(TOP)
	title:SetText("#daddonmap.title.text")
	title:SetDark(true)

	self.SizeFilter = vgui.Create("DNumSlider", controls)
	self.SizeFilter.Ready = false
	self.SizeFilter:SetEnabled(false)
	self.SizeFilter:SetText("#daddonmap.sizefilter.text")
	self.SizeFilter:SetMinMax(0.01, 10000)
	self.SizeFilter:SetValue(10000) -- 10GB
	self.SizeFilter:SetDark(true)
	self.SizeFilter:SizeToContents()
	self.SizeFilter:Dock(TOP)
	self.SizeFilter.OnValueChanged = function(this, val)

		if (!this.Ready) then return end

		-- dispatch cancel signal to cancellation token.
		if (self.SquareMap) then self.SquareMap:Cancel() end

		-- throttle heatmap to avoid unecessary cpu load.
		timer.Create("daddonmap_load_" .. tostring(self), 0.1, 1, function()
			if (IsValid(self)) then self:LoadAddons(val) end
		end)
	end
	self.SizeFilter.Ready = true

	self.AddonMap = vgui.Create("DPanel", self.Container)
	self.AddonMap:Dock(FILL)

	self.AddonMap.Paint = function(this, w, h)
		self:DrawMap(this, w, h)
	end

	self.AddonMap.TriggerCount = 0
	self.AddonMap.OnMousePressed = function(this, key)

		-- one time event to build addon map cache.
		this.TriggerCount = this.TriggerCount + 1
		if (this.TriggerCount == 2) then self:LoadAddons() end

		-- dispatcher.
		if (key == MOUSE_LEFT) then self:ClickAddon(this) end
		if (key == MOUSE_RIGHT) then self:RightClickAddon(this) end
	end
end

--- Save steamworks cache to disk
-- Schedules a delayed write of the Steamworks cache table to the
-- data folder as JSON. Uses a short timer to batch or defer frequent updates.
function PANEL:SaveSteamworksCache()
	timer.Create("daddonmap_steamworks_cache_" .. tostring(self), 2, 1, function()
		file.Write(CACHE_PATH, util.TableToJSON(steamworksCache))
	end)
end

--- Commit batch to map
-- Iterates over a subset of addon data and draws their workshop preview
-- icons onto the square map. Uses cached preview IDs when available,
-- otherwise queries Steamworks asynchronously and updates the cache.
-- Ensures rendering is aborted if the panel becomes invalid, the map
-- generation changes, or the operation is cancelled.
-- @param data table The full dataset of addon entries to render.
-- @param start number The starting index of the batch.
-- @param len number The number of entries to process in this batch.
function PANEL:CommitBatchToMap(data, start, len)

	-- failsafe.
	if (!IsValid(self)) then return end
	if (!data) then return end

	local token = self.SquareMap.CancellationToken
	local generation = self.SquareMap.Generation

	for i = start, start + len - 1 do

		-- failsafe, should never happen.
		if (!data[i]) then continue end

		local wsid = data[i].obj.wsid
		local previewid = steamworksCache[wsid]

		if (previewid) then

			-- attempt to fetch icon from disk rather than asking from steamworks.
			local previewIcon = AddonMaterial("cache/workshop/" .. previewid .. ".cache")
			if (!previewIcon) then continue end

			surface.SetDrawColor(255, 255, 255, 255)
			surface.SetMaterial(previewIcon)
			surface.DrawTexturedRect(self.SquareMap:RectToScreen(data[i]))
		else
			steamworks.FileInfo(wsid, function(info)

				if (!info) then return end

				-- process icon now rather than later to ensure caching even if token expired.
				local previewIcon = AddonMaterial("cache/workshop/" .. info.previewid .. ".cache")
				if (!previewIcon) then return end

				-- try commit.
				steamworksCache[wsid] = info.previewid
				self:SaveSteamworksCache()

				-- bail callback if generation changed.
				if (!IsValid(self)) then return end
				if (self.SquareMap.Generation != generation) then return end
				if (token.Cancelled) then return end

				-- force-push rendertarget since we are now in a callback branch.
				render.PushRenderTarget(self.SquareMapRT)
				cam.Start2D()

				surface.SetDrawColor(255, 255, 255, 255)
				surface.SetMaterial(previewIcon)
				surface.DrawTexturedRect(self.SquareMap:RectToScreen(data[i]))

				cam.End2D()
				render.PopRenderTarget()
			end)
		end
	end
end

--- Load and render addons
-- Collects installed addons and asynchronously generates their layout 
-- on the square map. Updates the render target in batches and tracks 
-- progress as rendering completes.
-- @param sizeFilter number|nil Maximum addon size in MB to include.
function PANEL:LoadAddons(sizeFilter)

	-- avoid redundant regeneration if the value hasn't changed.
	self.SizeFilter:SetEnabled(true)
	if (sizeFilter && sizeFilter == self.LastSizeFilter) then return end
	self.LastSizeFilter = sizeFilter
	self.SizeFilter.Ready = false

	local smallestSize = math.huge
	local largestSize = 0

	local addons = {}
	for k,v in ipairs(engine.GetAddons()) do

		-- stay up to date if game content change was triggered.
		if (v.size < smallestSize) then smallestSize = v.size end
		if (v.size > largestSize) then largestSize = v.size end

		if (bytesToMB(v.size) > (sizeFilter || 10000)) then continue end

		table.insert(addons, { value = v.size, obj = v })
	end

	smallestSize = bytesToMB(smallestSize)
	largestSize = bytesToMB(largestSize)

	-- clamp size filter when mutating addon list.
	self.SizeFilter:SetMinMax(smallestSize, largestSize)
	self.SizeFilter:SetDefaultValue(largestSize)
	if (!sizeFilter || sizeFilter > largestSize) then
		self.SizeFilter:ResetToDefaultValue()
	end

	local total = #addons
	local count = 0
	self.SquareMap:GenerateAsync(addons, function(data, start, len)

		render.PushRenderTarget(self.SquareMapRT)
		cam.Start2D()

		-- flush rendertarget on new generations.
		if (start == 1) then
			render.Clear(0, 0, 0, 0, true, true)
		end

		-- commit to render target in discrete async batches.
		self:CommitBatchToMap(data, start, len)

		cam.End2D()
		render.PopRenderTarget()

		count = count + len
		self.Progress = count / total
	end)

	-- filter is safe to be changed again.
	self.SizeFilter.Ready = true
end

--- Map think handler
-- Updates the square map each frame by advancing any pending asynchronous
-- generation or processing tasks.
function PANEL:Think()
	if (!self.SquareMap) then return end
	self.SquareMap:Tick()
end

--- Draw the addon map
-- Renders the deferred square map texture to the panel.
-- @param pnl panel The panel being drawn.
-- @param w number The width of the panel.
-- @param h number The height of the panel.
local color_red = Color(250, 80, 75)
function PANEL:DrawMap(pnl, w, h)

	if (!self.Progress) then
		local text = language.GetPhrase("#daddonmap.generate.text")
		local warning = language.GetPhrase("#daddonmap.generate.warning")
		draw.SimpleText(text, "ContentHeader", w / 2, h / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(warning, "DermaDefaultBold", w / 2, h / 2 + 30, color_red, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		return
	end

	if (self.Progress <= 0) then return end

	-- render addon square map.
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(self.SquareMapMat)
	surface.DrawTexturedRect(0, 0, w, h)

	if (self.Progress < 1) then

		surface.SetDrawColor(0, 0, 0, 200)
		surface.DrawRect(0, 0, w, h)

		draw.SimpleText(string.format("%d%%", self.Progress * 100), "ContentHeader", w / 2, h / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		return
	end

	local mx, my = input.GetCursorPos()
	local x, y = pnl:LocalToScreen(0, 0)

	-- bail if the cursor is currently outside the map.
	if (mx < x || my < y || mx > x + w || my > y + h) then return end

	local rect = self.SquareMap:GetRectAt(mx, my, x, y, w, h)
	if (!rect) then return end

	local rx, ry, rw, rh = self.SquareMap:LocalToScreen(rect, 0, 0, w, h)

	surface.SetDrawColor(0, 130, 255, 255)
	surface.DrawOutlinedRect(rx, ry, rw, rh, 5)
end

--- Get addon under cursor
-- Determines which addon entry is currently under the user's cursor based
-- on the square map layout and panel bounds.
-- @param pnl panel The panel used for coordinate translation.
-- @return table|nil The addon object at the cursor.
function PANEL:GetAddonAtCursor(pnl)

	local mx, my = input.GetCursorPos()
	local x, y = pnl:LocalToScreen(0, 0)
	local w = pnl:GetWide()
	local h = pnl:GetTall()

	local rect = self.SquareMap:GetRectAt(mx, my, x, y, w, h)
	if (!rect) then return end

	return rect.obj
end

--- Handle addon click
-- Retrieves the addon currently under the cursor and triggers the
-- OnClickAddon callback if a valid addon is found.
-- @param pnl panel The panel receiving the click event.
function PANEL:ClickAddon(pnl)
	local addon = self:GetAddonAtCursor(pnl)
	if (addon) then self:OnClickAddon(addon) end
end

function PANEL:OnClickAddon(addon)
	-- override
end

--- Handle addon right click
-- Retrieves the addon currently under the cursor and triggers the
-- OnClickAddon callback if a valid addon is found.
-- @param pnl panel The panel receiving the click event.
function PANEL:RightClickAddon(pnl)
	local addon = self:GetAddonAtCursor(pnl)
	if (addon) then self:OnRightClickAddon(addon) end
end

function PANEL:OnRightClickAddon(addon)
	-- override
end

vgui.Register("DAddonMap", PANEL, "EditablePanel")