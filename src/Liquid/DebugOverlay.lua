--!strict
--!native
--!optimize 2

-- Debug visualizations: contours, normals, cell centers, or grid view. Parametric not per-pixel

local Shape = require(script.Parent.Shape)
local Geometry = require(script.Parent.Geometry)
local Types = require(script.Parent.Types)

type ReconJob = Types.ReconJob
type LiquidParams = Types.LiquidParams

local sdfRoundedRect = Shape.sdfRoundedRect
local deriveShape = Shape.deriveShape
local MELT_SPAN_FLOOR = Geometry.MELT_SPAN_FLOOR

local band = bit32.band
local rshift = bit32.rshift

local CONTOUR_LEVELS = 9 -- family contours drawn between the rim and the center
local SWEEP_RATE = 0.15 -- animated sweep contours per second
local ARC_STEPS = 24 -- parametric steps along one corner arc

local DebugOverlay = {}

-- Blends a color into a pixel's RGB, leaving the mask alpha untouched
local function blendPixel(out: buffer, offset: number, r: number, g: number, b: number, a: number)
	local keep = 1 - a
	buffer.writeu8(out, offset, (buffer.readu8(out, offset) * keep + r * a + 0.5) // 1)
	buffer.writeu8(out, offset + 1, (buffer.readu8(out, offset + 1) * keep + g * a + 0.5) // 1)
	buffer.writeu8(out, offset + 2, (buffer.readu8(out, offset + 2) * keep + b * a + 0.5) // 1)
end

-- Tent-weighted round splat at continuous output coordinates
local function splat(
	out: buffer,
	outW: number,
	outH: number,
	x: number,
	y: number,
	radius: number,
	r: number,
	g: number,
	b: number,
	strength: number
)
	local invRadius = 1 / radius
	local x0 = math.max((x - radius) // 1, 0)
	local x1 = math.min((x + radius) // 1, outW - 1)
	local y0 = math.max((y - radius) // 1, 0)
	local y1 = math.min((y + radius) // 1, outH - 1)
	for py = y0, y1 do
		local dy = py + 0.5 - y
		for px = x0, x1 do
			local dx = px + 0.5 - x
			local w = 1 - math.sqrt(dx * dx + dy * dy) * invRadius
			if w > 0 then
				blendPixel(out, (py * outW + px) * 4, r, g, b, strength * w)
			end
		end
	end
end

-- Splats along a polyline at sub-pixel steps, so stroke opacity is
-- uniform along the path. points is a flat {x1, y1, x2, y2, ...} array
-- in output px.
local function strokePolyline(
	out: buffer,
	outW: number,
	outH: number,
	points: { number },
	radius: number,
	r: number,
	g: number,
	b: number,
	strength: number
)
	local ax, ay = points[1], points[2]
	splat(out, outW, outH, ax, ay, radius, r, g, b, strength)
	for i = 3, #points - 1, 2 do
		local bx, by = points[i], points[i + 1]
		local dx, dy = bx - ax, by - ay
		local length = math.sqrt(dx * dx + dy * dy)
		if length > 1e-6 then
			local steps = math.max(math.ceil(length / 0.75), 1)
			for k = 1, steps do
				local t = k / steps
				splat(out, outW, outH, ax + dx * t, ay + dy * t, radius, r, g, b, strength)
			end
		end
		ax, ay = bx, by
	end
end

-- A stroked line reads on any backdrop as a dark soft halo under a
-- bright core, so both passes share their geometry here
local function strokeLine(
	out: buffer,
	outW: number,
	outH: number,
	points: { number },
	width: number,
	r: number,
	g: number,
	b: number,
	strength: number
)
	strokePolyline(out, outW, outH, points, width * 2, 0, 0, 0, strength * 0.4)
	strokePolyline(out, outW, outH, points, width, r, g, b, strength)
end

-- One quadrant of a rounded-rect contour as folded window-px points:
-- outer half-extents (hx, hy), corner radius rho, superellipse exponent
-- m. Runs from the vertical centerline (0, hy) along the edge, around
-- the corner arc, to the horizontal centerline (hx, 0).
local function contourQuadrant(hx: number, hy: number, rho: number, m: number): { number }
	local points = { 0, hy }
	local cornerX, cornerY = hx - rho, hy - rho
	if rho > 1e-3 then
		local power = 2 / m
		for k = ARC_STEPS, 0, -1 do
			local t = k / ARC_STEPS * (math.pi / 2)
			table.insert(points, cornerX + rho * math.cos(t) ^ power)
			table.insert(points, cornerY + rho * math.sin(t) ^ power)
		end
	else
		table.insert(points, hx)
		table.insert(points, hy)
	end
	table.insert(points, hx)
	table.insert(points, 0)
	return points
end

-- Draws the depth-d contour of a family, mirrored into all four
-- quadrants. family returns (corner radius, exponent) at a depth.
local function drawFamilyContour(
	job: ReconJob,
	halfW: number,
	halfH: number,
	family: (d: number) -> (number, number),
	d: number,
	width: number,
	r: number,
	g: number,
	b: number,
	strength: number
)
	local hx, hy = halfW - d, halfH - d
	if hx <= 0 or hy <= 0 then
		return
	end
	local rho, m = family(d)
	local quadrant = contourQuadrant(hx, hy, rho, m)
	local out, outW, outH = job.Out, job.OutW, job.OutH
	local invStepX, invStepY = 1 / job.StepX, 1 / job.StepY
	for sy = -1, 1, 2 do
		for sx = -1, 1, 2 do
			local mirrored = table.create(#quadrant)
			for i = 1, #quadrant - 1, 2 do
				table.insert(mirrored, (halfW + sx * quadrant[i]) * invStepX)
				table.insert(mirrored, (halfH + sy * quadrant[i + 1]) * invStepY)
			end
			strokeLine(out, outW, outH, mirrored, width, r, g, b, strength)
		end
	end
end

-- Level sets between the rim and the center, of the raw distance field
-- (melt false: rounded rects sharpening to square corners as the radius
-- runs out) or of the melting contour family (melt true: the same
-- shallow sets relaxing to deep circles instead). The melt mode also
-- sweeps one bright contour from the outline down to the deepest set,
-- on the wall clock, so passes animate it.
function DebugOverlay.drawContourOverlay(job: ReconJob, params: LiquidParams, melt: boolean)
	local winW, winH = job.StepX * job.OutW, job.StepY * job.OutH
	local halfW, halfH, radius, _, _, n = deriveShape(params, winW, winH)
	local halfMin = math.min(halfW, halfH)
	local invMeltSpan = 1 / math.max(radius, MELT_SPAN_FLOOR * halfMin)

	local function family(d: number): (number, number)
		if melt then
			local v = d * invMeltSpan
			if v > 1 then
				v = 1
			end
			local beta = v * v * v * (v * (v * 6 - 15) + 10)
			return math.max(radius - d + beta * (halfMin - radius), 0), 2 + (n - 2) * (1 - beta)
		end
		return math.max(radius - d, 0), n
	end

	for level = 1, CONTOUR_LEVELS do
		local d = level / (CONTOUR_LEVELS + 1) * halfMin
		drawFamilyContour(job, halfW, halfH, family, d, 1.2, 255, 255, 255, 0.55)
	end
	if melt then
		local sweep = (os.clock() * SWEEP_RATE % 1) * CONTOUR_LEVELS / (CONTOUR_LEVELS + 1) * halfMin
		drawFamilyContour(job, halfW, halfH, family, sweep, 1.8, 255, 190, 70, 0.95)
	end
end

-- The displacement's normal field as an arrow lattice over the
-- refracting band: melted normals, or the raw distance field's creased
-- normals when rawField is set, matching what the geometry bake would
-- produce under the same flag.
function DebugOverlay.drawNormalOverlay(job: ReconJob, params: LiquidParams, rawField: boolean)
	local out, aux = job.Out, job.Aux
	local outW, outH = job.OutW, job.OutH
	local stepX, stepY = job.StepX, job.StepY
	local winW, winH = stepX * outW, stepY * outH
	local halfW, halfH, radius, insetX, insetY, n, invN = deriveShape(params, winW, winH)
	local halfMin = math.min(halfW, halfH)
	local invMeltSpan = 1 / math.max(radius, MELT_SPAN_FLOOR * halfMin)
	local thickness = params.thickness

	-- Replicates the contour solve in Geometry.buildDisplacementRows at
	-- one point; see that file for the derivation
	local function contourAt(apx: number, apy: number, d: number): (number, number, number, number)
		local v = d * invMeltSpan
		if v > 1 then
			v = 1
		end
		local beta = v * v * v * (v * (v * 6 - 15) + 10)
		local rho = radius - d + beta * (halfMin - radius)
		if rho < 0 then
			rho = 0
		end
		local m = 2 + (n - 2) * (1 - beta)
		local qx = apx - (halfW - d - rho)
		local qy = apy - (halfH - d - rho)
		local g
		if qx > 0 and qy > 0 then
			g = (qx ^ m + qy ^ m) ^ (1 / m) - rho
		else
			g = (if qx > qy then qx else qy) - rho
		end
		return g, qx, qy, m
	end

	local spacing = math.max(math.min(outW, outH) / 16, 7) -- output px between arrows
	local shaft = spacing * 0.36 -- half-length of an arrow
	local head = spacing * 0.3
	local rows = (outH / spacing) // 1
	local columns = (outW / spacing) // 1
	for row = 0, rows - 1 do
		local y = (row + 0.5) * spacing + (outH - rows * spacing) / 2
		local wy = y * stepY
		local py = wy - halfH
		local absPy = math.abs(py)
		local sy = if py >= 0 then 1 else -1
		for column = 0, columns - 1 do
			local x = (column + 0.5) * spacing + (outW - columns * spacing) / 2
			if buffer.readu8(aux, ((y // 1) * outW + x // 1) * 4 + 2) == 0 then
				continue
			end
			local wx = x * stepX
			local px = wx - halfW
			local absPx = math.abs(px)
			local sx = if px >= 0 then 1 else -1

			local depth: number, qx: number, qy: number, m: number
			if rawField then
				qx, qy, m = absPx - insetX, absPy - insetY, n
				depth = math.max(-sdfRoundedRect(qx, qy, radius, n, invN), 0)
			else
				depth = 0
				local g
				g, qx, qy, m = contourAt(absPx, absPy, 0)
				if g < 0 then
					local lo, hi = 0, halfMin
					for _ = 1, 20 do
						local mid = (lo + hi) * 0.5
						if contourAt(absPx, absPy, mid) < 0 then
							lo = mid
						else
							hi = mid
						end
					end
					depth = (lo + hi) * 0.5
					g, qx, qy, m = contourAt(absPx, absPy, depth)
				end
			end
			-- Only the refracting band displaces, so arrows outside it
			-- would just clutter the figure
			if depth >= thickness then
				continue
			end

			local dirX, dirY
			if qx > 0 and qy > 0 then
				dirX = sx * qx ^ (m - 1)
				dirY = sy * qy ^ (m - 1)
			elseif qy >= qx then
				dirX = 0
				dirY = sy
			else
				dirX = sx
				dirY = 0
			end
			local length = math.sqrt(dirX * dirX + dirY * dirY)
			if length < 1e-9 then
				continue
			end
			dirX, dirY = dirX / length, dirY / length

			-- Shaft through the lattice point, plus the two head strokes,
			-- pointing along the outward normal
			local tipX, tipY = x + dirX * shaft, y + dirY * shaft
			local headX = -dirX * 0.82 -- cos(±145 degrees) folded into the
			local headY = -dirY * 0.82 -- rotation applied to the direction
			local sideX, sideY = -dirY * 0.57, dirX * 0.57
			strokeLine(out, outW, outH, {
				x - dirX * shaft,
				y - dirY * shaft,
				tipX,
				tipY,
				tipX + (headX + sideX) * head,
				tipY + (headY + sideY) * head,
				tipX,
				tipY,
				tipX + (headX - sideX) * head,
				tipY + (headY - sideY) * head,
			}, 1, 255, 255, 255, 0.85)
		end
	end
end

-- The source grid's cell centers as dots: the warped centers the sampler
-- actually reads (from the warp's position buffers), or the uniform
-- lattice the same grid would use unwarped, for comparison.
function DebugOverlay.drawCellCenterOverlay(job: ReconJob, gridPosX: buffer, gridPosY: buffer, uniform: boolean)
	local out = job.Out
	local outW, outH = job.OutW, job.OutH
	local gridW, gridH = job.GridW, job.GridH
	local invStepX, invStepY = 1 / job.StepX, 1 / job.StepY
	local cellW = job.StepX * outW / gridW -- uniform spacing in window px
	local cellH = job.StepY * outH / gridH
	for j = 0, gridH - 1 do
		local y = (if uniform then (j + 0.5) * cellH else buffer.readf32(gridPosY, j * 4)) * invStepY
		local rowBase = j * gridW
		for i = 0, gridW - 1 do
			local x = (if uniform then (i + 0.5) * cellW else buffer.readf32(gridPosX, (rowBase + i) * 4)) * invStepX
			splat(out, outW, outH, x, y, 2.2, 0, 0, 0, 0.5)
			splat(out, outW, outH, x, y, 1.2, 255, 255, 255, 0.95)
		end
	end
end

-- Replaces the render with the live source grid, one cell per output
-- block, brightened along the sampler's refresh front so the sequential
-- walk reads as a sweep; highlightFront false shows the stored colors
-- alone. frontIndex is the sampler's next cell; the walk is cyclic, so
-- each cell's distance behind the front is its age. Completes the job
-- synchronously, like the heatmap.
function DebugOverlay.renderGridView(job: ReconJob, frontIndex: number, highlightFront: boolean)
	local out, grid = job.Out, job.Grid
	local outW, outH = job.OutW, job.OutH
	local gridW, gridH = job.GridW, job.GridH
	local cellCount = gridW * gridH
	local invCellCount = 1 / cellCount
	local newest = frontIndex - 1
	local boostScale = if highlightFront then 0.65 else 0
	for y = 0, outH - 1 do
		local gridRow = y * gridH // outH * gridW
		local rowOffset = y * outW * 4
		for x = 0, outW - 1 do
			local cell = gridRow + x * gridW // outW
			local color = buffer.readu32(grid, cell * 4)
			local age = (newest - cell) % cellCount * invCellCount
			local fade = 1 - age
			local fade4 = fade * fade * fade * fade
			local boost = fade4 * fade4 * fade4 * boostScale -- a tail about a tenth of the walk long
			local r = band(color, 0xFF)
			local g = band(rshift(color, 8), 0xFF)
			local b = band(rshift(color, 16), 0xFF)
			buffer.writeu32(
				out,
				rowOffset + x * 4,
				(r + (255 - r) * boost + 0.5) // 1
					+ ((g + (255 - g) * boost + 0.5) // 1) * 0x100
					+ ((b + (255 - b) * boost + 0.5) // 1) * 0x10000
					+ 0xFF000000
			)
		end
	end
	job.Row = outH
end

return DebugOverlay
