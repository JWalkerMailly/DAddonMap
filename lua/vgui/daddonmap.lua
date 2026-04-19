
local squaremap = include("includes/modules/squaremap.lua")

local PANEL = {}
local CACHE_PATH = "daddonmap_steamworks_cache.json"

-- preview id caching.
local steamworksCache = {}

local function bytesToMB(bytes)
	return bytes / 1e6
end

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

function PANEL:Setup()

	self.SquareMap    = squaremap.new(1024, 1024)
	self.SquareMapRT  = GetRenderTarget("daddonmap", 1024, 1024)
	self.SquareMapMat = CreateMaterial("daddonmap", "UnlitGeneric", {
		["$basetexture"] = "daddonmap",
		["$translucent"] = 1
	})

	loadSteamworksCache()
end

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
	title:SetText("Addon Size Map")
	title:SetDark(true)

	self.SizeFilter = vgui.Create("DNumSlider", controls)
	self.SizeFilter.Ready = false
	self.SizeFilter:SetEnabled(false)
	self.SizeFilter:SetText("Size Filter (MB)")
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

function PANEL:SaveSteamworksCache()
	timer.Create("daddonmap_steamworks_cache_" .. tostring(self), 2, 1, function()
		file.Write(CACHE_PATH, util.TableToJSON(steamworksCache))
	end)
end

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

	-- filter is safe be be changed again.
	self.SizeFilter.Ready = true
end

function PANEL:Think()
	if (!self.SquareMap) then return end
	self.SquareMap:Tick()
end

local color_red = Color(250, 80, 75)
function PANEL:DrawMap(pnl, w, h)

	if (!self.Progress) then
		draw.SimpleText("Click twice to generate addon size map", "ContentHeader", w / 2, h / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("This is an intensive process, load will depend on number of addons.", "DermaDefaultBold", w / 2, h / 2 + 30, color_red, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
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

function PANEL:GetAddonAtCursor(pnl)

	local mx, my = input.GetCursorPos()
	local x, y = pnl:LocalToScreen(0, 0)
	local w = pnl:GetWide()
	local h = pnl:GetTall()

	local rect = self.SquareMap:GetRectAt(mx, my, x, y, w, h)
	if (!rect) then return end

	return rect.obj
end

function PANEL:ClickAddon(pnl)
	local addon = self:GetAddonAtCursor(pnl)
	if (addon) then self:OnClickAddon(addon) end
end

function PANEL:OnClickAddon(addon)
	-- override
end

function PANEL:RightClickAddon(pnl)
	local addon = self:GetAddonAtCursor(pnl)
	if (addon) then self:OnRightClickAddon(addon) end
end

function PANEL:OnRightClickAddon(addon)
	-- override
end

vgui.Register("DAddonMap", PANEL, "EditablePanel")