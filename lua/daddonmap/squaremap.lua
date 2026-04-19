
--- squaremap.lua
-- A squarified treemap layout generator with asynchronous execution support.
-- This module converts weighted datasets into space-filling rectangular layouts,
-- where each item's area is proportional to its value. It uses the squarified
-- treemap algorithm to produce visually balanced rectangles with good aspect ratios.
-- LDoc comments were redacted with the help of Claude AI for sanity.
-- resources: https://vanwijk.win.tue.nl/stm.pdf
local squaremap = {}
squaremap.__index = squaremap

function squaremap.new(width, height)

	local map = setmetatable({}, squaremap)

	map.CancellationToken = { Cancelled = false }

	map.Width  = width  || 512
	map.Height = height || 512

	map.Nodes       = {}
	map._sortedData = {}
	map._rowBuffer  = {}

	return map
end

local function pixelRound(x)
	return math.floor(x + 0.5)
end

--- Screen To Local
-- Converts screen-space coordinates into map-local space.
-- Reverses the effects of viewport offset and scaling applied during rendering.
-- @param x number Screen-space X coordinate.
-- @param y number Screen-space Y coordinate.
-- @param vx number Viewport X offset.
-- @param vy number Viewport Y offset.
-- @param vw number Viewport width.
-- @param vh number Viewport height.
-- @return number x Local-space X coordinate.
-- @return number y Local-space Y coordinate.
function squaremap:ScreenToLocal(x, y, vx, vy, vw, vh)

	vw = vw || self.Width
	vh = vh || self.Height

	x = (x - (vx || 0)) * (self.Width / vw)
	y = (y - (vy || 0)) * (self.Height / vh)

	return x, y
end

--- Rect To Screen
-- Converts rectangle coordinates into pixel-aligned screen-space values.
-- Coordinates are rounded to pixel boundaries to avoid subpixel rendering issues.
-- @param x number|table X coordinate or node.
-- @param y number Y coordinate (ignored if x is a table).
-- @param w number Width. 
-- @param h number Height.
-- @return x, y, w, h
function squaremap:RectToScreen(x, y, w, h)

	if (!x) then return 0, 0, 0, 0 end

	if (istable(x)) then
		x, y, w, h = x.x, x.y, x.w, x.h
	end

	local x1 = pixelRound(x)
	local y1 = pixelRound(y)
	local x2 = pixelRound(x + w)
	local y2 = pixelRound(y + h)

	return x1, y1, x2 - x1, y2 - y1
end

--- Local To Screen
-- Converts a rectangle from map-local space into screen-space coordinates.
-- Applies scaling based on the map dimensions and optional viewport size,
-- then offsets the result by the viewport position.
-- @param rect table Rectangle in local space.
-- @param vx number Viewport X offset.
-- @param vy number Viewport Y offset.
-- @param vw number Viewport width.
-- @param vh number Viewport height.
-- @return table Rectangle in screen space.
function squaremap:LocalToScreen(rect, vx, vy, vw, vh)

	vw = vw || self.Width
	vh = vh || self.Height

	local scaleW = (vw / self.Width)
	local scaleH = (vh / self.Height)
	local x = rect.x * scaleW + (vx || 0)
	local y = rect.y * scaleH + (vy || 0)
	local w = rect.w * scaleW
	local h = rect.h * scaleH

	return self:RectToScreen(x, y, w, h)
end

--- Get Rect At
-- Returns the rect at the given screen-space coordinates.
-- Coordinates are first transformed into the map’s local space.
-- Relies on Build Index for O(1) filtering.
-- @param x number Screen-space X coordinate.
-- @param y number Screen-space Y coordinate.
-- @param vx number Viewport X offset.
-- @param vy number Viewport Y offset.
-- @param vw number Viewport width.
-- @param vh number Viewport height.
-- @return table Node if any.
function squaremap:GetRectAt(x, y, vx, vy, vw, vh)

	-- wait for index to be built.
	if (!self._grid) then return end

	-- O(1) cell lookup, then scan only the candidates in that cell
	x, y = self:ScreenToLocal(x, y, vx, vy, vw, vh)
	local cellSize = self._cellSize
	local key      = math.floor(y / cellSize) * self._gridCols + math.floor(x / cellSize)
	local cell     = self._grid[key]

	if (!cell) then return nil end

	for i = 1, #cell do

		local r = cell[i]

		-- candidate found.
		if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) then
			return r
		end
	end

	return nil
end

--- Get Kernel Size
-- Computes an appropriate kernel size based on the map dimensions and node count.
-- Thresholds were tuned using datasets with thousands of nodes in a 1024×1024 area.
-- The resulting kernel size scales proportionally with the map size.
-- @param map squaremap Dataset to evaluate.
-- @return integer Kernel size.
local function getKernelSize(map)

	local n = #map.Nodes
	local base = math.max(map.Width, map.Height)

	local divisor
	if (n < 100)      then divisor = 16
	elseif (n < 500)  then divisor = 32
	elseif (n < 2000) then divisor = 64
	else                   divisor = 128
	end

	return math.max(1, math.floor(base / divisor))
end

--- Build Index
-- Builds a spatial grid index over all generated rectangles for fast point lookup.
-- Each rectangle is inserted into all grid cells it overlaps, enabling near O(1)
-- queries when locating rectangles by screen or local coordinates.
-- @param map table Target squaremap instance containing.
local function buildIndex(map)

	local cellSize = getKernelSize(map)
	map._cellSize = cellSize
	map._grid = {}

	local cols = math.ceil(map.Width  / cellSize)
	local rows = math.ceil(map.Height / cellSize)
	map._gridCols = cols
	map._gridRows = rows

	local grid = map._grid
	local rects = map.Nodes

	for i = 1, #rects do

		-- find which cells this rect overlaps.
		local r = rects[i]
		local x1 = math.floor(r.x / cellSize)
		local y1 = math.floor(r.y / cellSize)
		local x2 = math.floor((r.x + r.w - 1) / cellSize)
		local y2 = math.floor((r.y + r.h - 1) / cellSize)

		for cy = y1, y2 do
			for cx = x1, x2 do
				local key = cy * cols + cx
				if (!grid[key]) then grid[key] = {} end
				grid[key][#grid[key] + 1] = r
			end
		end
	end
end

--- Horizontal Row Layout Helper
local function layoutRowH(map, row, len, x, y, w, h)

	local sum = 0
	for i = 1, len do sum = sum + row[i].area end

	local rowH    = sum / w
	local invRowH = 1 / rowH
	local cx      = x
	local rects   = map.Nodes
	local base    = #rects

	for i = 1, len do
		local item = row[i]
		local rw   = item.area * invRowH
		rects[base + i] = { x = cx, y = y, w = rw, h = rowH, obj = item.obj }
		cx = cx + rw
	end

	return x, y + rowH, w, h - rowH
end

--- Vertical Row Layout Helper
local function layoutRowV(map, row, len, x, y, w, h)

	local sum = 0
	for i = 1, len do sum = sum + row[i].area end

	local rowW    = sum / h
	local invRowW = 1 / rowW
	local cy      = y
	local rects   = map.Nodes
	local base    = #rects

	for i = 1, len do
		local item = row[i]
		local rh   = item.area * invRowW
		rects[base + i] = { x = x, y = cy, w = rowW, h = rh, obj = item.obj }
		cy = cy + rh
	end

	return x + rowW, y, w - rowW, h
end

--- Aspect Ratio
-- Computes the worst aspect ratio for a candidate row in the squarify algorithm.
-- Used to evaluate how square a row of rectangles will be when laid out along a given side.
local function aspectRatio(sumArea, minArea, maxArea, sideLength)

	local s2 = sumArea * sumArea
	local w2 = sideLength * sideLength
	local r1 = w2 * maxArea / s2
	local r2 = s2 / (w2 * minArea)

	return r1 > r2 && r1 || r2
end

--- Squarify Async
-- Yields based on elapsed clock time per frame processing as many rows as 
-- possible within the time budget before suspending.
-- @param map table Target squaremap instance.
-- @param items table Array of items.
-- @param token table Cancellation token.
-- @param co thread Coroutine used for yielding.
-- @param budgetMs number Time budget in milliseconds before yielding.
-- @param progressCallback function Optional callback invoked during layout progress.
local function squarifyAsync(map, items, token, budgetMs, progressCallback)

	local x, y, w, h = 0, 0, map.Width, map.Height
	local row        = map._rowBuffer
	local n          = #items
	local itemIdx    = 1
	local frameStart = SysTime()

	while (itemIdx <= n) do

		if (token && token.Cancelled) then return end

		local isHorizontal = w < h
		local side         = isHorizontal && w || h
		local rowLen  = 0
		local sumArea = 0
		local minArea = math.huge
		local maxArea = 0

		while (itemIdx <= n) do

			if (token && token.Cancelled) then return end

			local item = items[itemIdx]
			local a    = item.area

			if rowLen > 0 then
				local prevWorst = aspectRatio(sumArea, minArea, maxArea, side)
				local currWorst = aspectRatio(sumArea + a, math.min(minArea, a), math.max(maxArea, a), side)

				if prevWorst < currWorst then break end
			end

			rowLen      = rowLen + 1
			row[rowLen] = item
			itemIdx     = itemIdx + 1
			sumArea     = sumArea + a
			minArea     = a < minArea && a || minArea
			maxArea     = a > maxArea && a || maxArea
		end

		local count = #map.Nodes
		if isHorizontal then
			x, y, w, h = layoutRowH(map, row, rowLen, x, y, w, h)
		else
			x, y, w, h = layoutRowV(map, row, rowLen, x, y, w, h)
		end

		progressCallback(map.Nodes, count + 1, rowLen)

		if ((SysTime() - frameStart) * 1000) >= budgetMs then
			coroutine.yield()
			if (token && token.Cancelled) then return end
			frameStart = SysTime()
		end
	end
end

--- Merge
-- Merges two sorted sub-ranges of t into out.
local function merge(t, out, lo, mid, hi)

	local i, j, k = lo, mid + 1, lo
	while (i <= mid && j <= hi) do
		if t[i].value >= t[j].value then
			out[k] = t[i]; i = i + 1
		else
			out[k] = t[j]; j = j + 1
		end
		k = k + 1
	end

	while (i <= mid) do out[k] = t[i]; i = i + 1; k = k + 1 end
	while (j <= hi)  do out[k] = t[j]; j = j + 1; k = k + 1 end
end

--- Merge-Sort Async
-- Iterative merge sort that yields when the frame budget is exceeded.
-- Operates on map._sortedData in-place using a scratch buffer.
-- https://algs4.cs.princeton.edu/22mergesort/
-- @param map table Target squaremap instance.
-- @param token table Cancellation token.
-- @param budgetMs number Time budget in milliseconds before yielding.
local function sortAsync(map, token, budgetMs)

	local n   = #map._sortedData
	local src = {}
	local dst = {}
	for i = 1, n do src[i] = map._sortedData[i] end

	local frameStart = SysTime()
	local width = 1

	while (width < n) do

		if token && token.Cancelled then return end

		local lo = 1
		while (lo <= n) do

			if token && token.Cancelled then return end

			local mid = math.min(lo + width - 1, n)
			local hi  = math.min(lo + width * 2 - 1, n)

			if mid < hi then
				merge(src, dst, lo, mid, hi)
			else
				-- odd chunk with no pair, copy as-is.
				for i = lo, hi do dst[i] = src[i] end
			end

			lo = lo + width * 2

			if ((SysTime() - frameStart) * 1000) >= budgetMs then
				coroutine.yield()
				if token && token.Cancelled then return end
				frameStart = SysTime()
			end
		end

		-- swap buffers for next pass.
		src, dst = dst, src
		width = width * 2
	end

	-- write sorted result back.
	for i = 1, n do map._sortedData[i] = src[i] end
end

--- Normalize
-- Converts raw input values into proportional area that fill the entire map.
local function normalize(map, data)

	local sum = 0
	local totalArea = map.Width * map.Height
	for i = 1, #data do
		sum = sum + data[i].value
	end

	local inv = 1 / sum
	for i = 1, #data do
		data[i].area = data[i].value * inv * totalArea
	end
end

--- Generate Async
-- Asynchronously generates a squarified treemap layout from input data.
-- Cancels any in-progress generation before starting a new one. The layout
-- is built incrementally using a coroutine.
-- @param data table Array of input items.
-- @param progressCallback function Optional callback invoked during generation progress.
-- @param finishedCallback function Optional callback invoked when generation terminates.
-- @param budgetMs number Optional time budget in milliseconds per tick.
function squaremap:GenerateAsync(data, progressCallback, finishedCallback, budgetMs)

	if (self.CancellationToken) then
		self.CancellationToken.Cancelled = true
	end

	self._grid     = nil
	self._cellSize = nil
	self._gridCols = nil
	self._gridRows = nil

	local token = { Cancelled = false }
	self.CancellationToken = token

	self.Generation  = (self.Generation || 0) + 1
	local generation = self.Generation
	budgetMs         = budgetMs || 2
	progressCallback = progressCallback || function() end

	local rects = self.Nodes
	for i = #rects, 1, -1 do rects[i] = nil end

	local sorted = self._sortedData
	for i = #sorted, 1, -1 do sorted[i] = nil end
	for i = 1, #data do sorted[i] = data[i] end

	local co = coroutine.create(function()

		sortAsync(self, token, budgetMs)
		if (token && token.Cancelled) then return end

		normalize(self, sorted)
		squarifyAsync(self, sorted, token, budgetMs, progressCallback)

		if (generation == self.Generation) then
			buildIndex(self)
		end

		if (finishedCallback) then finishedCallback() end
	end)

	self._coroutine = co
	coroutine.resume(co)
end

--- Tick
-- Resumes the in-progress generation coroutine if one is suspended.
-- Must be called from an update loop.
-- Intended to be called each frame.
-- @return boolean True if the coroutine is still running, false if done or absent.
function squaremap:Tick()

	local co = self._coroutine
	if (!co) then return false end

	local status = coroutine.status(co)
	if (status != "suspended") then return false end

	local ok, err = coroutine.resume(co)
	if (!ok) then
		ErrorNoHalt("squaremap coroutine error: " .. tostring(err))
		self._coroutine = nil
		return false
	end

	return coroutine.status(co) == "suspended"
end

--- Cancel
-- Helper function to invalidate the current cancellation token.
function squaremap:Cancel()
	self.CancellationToken.Cancelled = true
end

--- Get Rects
-- Helper function to get the computed rects of the square map.
-- Rects size and width are always in map's local space system.
-- @return table Nodes.
function squaremap:GetRects()
	return self.Nodes
end

return squaremap