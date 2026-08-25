--!strict
--!native
--!optimize 2

-- Continuous density warp: grid cells concentrate where refraction fetches land. Builds lookup tables for sampler and reconstruction

local Shape = require(script.Parent.Shape)
local Refraction = require(script.Parent.Refraction)
local Types = require(script.Parent.Types)

type LiquidParams = Types.LiquidParams

local sdfRoundedRect = Shape.sdfRoundedRect
local deriveShape = Shape.deriveShape
local edgeFactorAt = Refraction.edgeFactorAt
local DISP_CONST = Refraction.DISP_CONST
local FETCH_ROOM = Refraction.FETCH_ROOM

local WARP_CDF_STEPS = 1024 -- density integration resolution
local WARP_LUT_SIZE = 512 -- window-position to grid-coord map entries
local WARP_LUT_MAX = WARP_LUT_SIZE - 1
local DEMAND_BINS = 128 -- resolution of the depth-demand profile and its field samples
local DEMAND_SCAN_STEPS = 512 -- depths pushed through the refraction profile
local WARP_DENSITY_FLOOR = 0.35 -- keeps unread bands warm for blur and warm-start

local Warp = {}

Warp.WARP_LUT_MAX = WARP_LUT_MAX

-- Skip rebuild when relayout changes no fetch-moving parameters
function Warp.warpKey(
	gridW: number,
	gridH: number,
	winW: number,
	winH: number,
	params: LiquidParams,
	maxDensity: number
): string
	return string.format(
		"%d:%d:%d:%d:%.1f:%.2f:%.2f:%.3f:%.4f:%.2f",
		gridW,
		gridH,
		math.round(winW),
		math.round(winH),
		params.cornerRadius,
		params.superEllipseFactor,
		params.thickness,
		params.refractionFactor,
		params.chromaticAberration,
		maxDensity
	)
end

-- Runs two 3-tap smoothing passes over a demand histogram, in place, to
-- soften scan and marginal noise and the fold caustic.
local function smoothHistogram(demand: { number })
	for _ = 1, 2 do
		local prev = demand[1]
		for b = 1, DEMAND_BINS do
			local current = demand[b]
			local following = if b < DEMAND_BINS then demand[b + 1] else current
			demand[b] = (prev + 2 * current + following) * 0.25
			prev = current
		end
	end
end

-- Clamped linear interpolation into a demand histogram at the fractional
-- bin index exactBin
local function sampleDemand(demand: { number }, exactBin: number): number
	if exactBin < 0 then
		exactBin = 0
	elseif exactBin > DEMAND_BINS - 1 then
		exactBin = DEMAND_BINS - 1
	end
	local b0 = exactBin // 1
	local fraction = exactBin - b0
	local d0 = demand[b0 + 1]
	local d1 = demand[math.min(b0 + 2, DEMAND_BINS)]
	return d0 + (d1 - d0) * fraction
end

-- Scratch for the axis CDF. buildAxisFromDemand fully rewrites it each call.
local cdfScratch: { number } = table.create(WARP_CDF_STEPS + 1)

-- Turns one axis's demand histogram into the warp outputs for that axis,
-- written in place at the given byte offsets:
--   positions: gridN f32 cell centers in window coordinates, from the
--     inverse CDF, so cells land denser where demand is higher.
--   lut: WARP_LUT_SIZE f32 entries mapping window position to continuous
--     grid coordinate, from the forward CDF, used by reconstruction.
-- Both come from the same CDF, so a cell center maps back to exactly its
-- own index, keeping sampling and reconstruction consistent.
-- Demand is clamped to [WARP_DENSITY_FLOOR, maxDensity]: the floor keeps
-- unread bands warm for blur and resize warm-starts, the cap bounds the
-- fold caustic's infinite-demand spike.
local function buildAxisFromDemand(
	demand: { number },
	gridN: number,
	extent: number,
	maxDensity: number,
	positions: buffer,
	positionsOffset: number,
	lut: buffer,
	lutOffset: number
)
	smoothHistogram(demand)

	local invBinWidth = DEMAND_BINS / (extent / 2)

	-- CDF of the clamped demand over the axis (symmetric about the center)
	local step = extent / WARP_CDF_STEPS
	local cdf = cdfScratch
	local total = 0
	cdf[1] = 0
	for i = 1, WARP_CDF_STEPS do
		local x = (i - 0.5) * step
		local density = math.clamp(
			sampleDemand(demand, math.min(x, extent - x) * invBinWidth - 0.5),
			WARP_DENSITY_FLOOR,
			maxDensity
		)
		total += density * step
		cdf[i + 1] = total
	end

	-- Inverse CDF: place each grid cell center at its equal-mass position
	local walkIndex = 1
	for i = 0, gridN - 1 do
		local target = (i + 0.5) / gridN * total
		while walkIndex < WARP_CDF_STEPS and cdf[walkIndex + 1] < target do
			walkIndex += 1
		end
		local c0 = cdf[walkIndex]
		local c1 = cdf[walkIndex + 1]
		local fraction = if c1 > c0 then (target - c0) / (c1 - c0) else 0
		buffer.writef32(positions, positionsOffset + i * 4, (walkIndex - 1 + fraction) * step)
	end

	-- Forward CDF: extent position -> continuous grid coordinate
	local gridScale = gridN / total
	for j = 0, WARP_LUT_MAX do
		local exactStep = j / WARP_LUT_MAX * WARP_CDF_STEPS
		local i0 = math.min(exactStep // 1, WARP_CDF_STEPS - 1)
		local fraction = exactStep - i0
		local mass = cdf[i0 + 1] + (cdf[i0 + 2] - cdf[i0 + 1]) * fraction
		buffer.writef32(lut, lutOffset + j * 4, math.clamp(mass * gridScale - 0.5, 0, gridN - 1))
	end
end

-- Builds the continuous density warp: a conditional-CDF (non-separable)
-- warp that makes the sampling lattice follow the window shape. The
-- demand profile is 1D in SDF depth — displacement runs along the SDF
-- normal, so a fetch from depth p lands at exactly p + reach for any
-- shape. A 1D scan pushes every depth (with the dispersion spread)
-- through the refraction profile, and the 2D demand field is that
-- profile evaluated at each point's SDF depth. No bin noise, so the
-- caustic band follows the shape's curve exactly (a 2D scatter histogram
-- showed its bin noise as concentric ripples).
--
-- Grid rows come from the field's y marginal; each row then gets its own
-- x warp from the field along that row — marginal times conditional
-- reproduces the 2D density. The depth profile omits the tangential
-- convergence at corners, understating magnitude somewhat at the caps.
--
-- Refraction is inward-only, so the window's outermost band is read by
-- no output pixel and drops to the density floor; that budget moves into
-- the band the magnified bezel content reads from, and the interior.
-- uniform (Config.DEBUG_UNIFORM_WARP) flattens the demand to 1, yielding
-- the uniform lattice the warp exists to improve on; the caller must
-- fold the flag into the warp key.
function Warp.buildWarp(
	gridW: number,
	gridH: number,
	winW: number,
	winH: number,
	params: LiquidParams,
	maxDensity: number,
	uniform: boolean?
): (buffer, buffer, buffer, buffer)
	local halfW, halfH, radius, insetX, insetY, n, invN = deriveShape(params, winW, winH)
	local halfMin = math.min(halfW, halfH)
	local thickness = params.thickness
	local invRefFactor = 1 / params.refractionFactor
	local spread = params.chromaticAberration

	-- 1D pushforward of fetch depths, as density relative to uniform.
	-- Depths go through edgeFactorAt exactly as the displacement bake
	-- does, so the profile matches the render precisely.
	local depthBin = halfMin / DEMAND_BINS
	local invDepthBin = 1 / depthBin
	local demand = table.create(DEMAND_BINS, if uniform then 1 else 0)
	if not uniform then
		local scanStep = halfMin / DEMAND_SCAN_STEPS
		local weight = scanStep * invDepthBin / 3
		local maxScale = edgeFactorAt(0, thickness, invRefFactor) * DISP_CONST
		local roomBase = FETCH_ROOM * halfMin
		for i = 0, DEMAND_SCAN_STEPS - 1 do
			local p = (i + 0.5) * scanStep
			-- Inward fetch reach in px; zero beyond the refracting band
			local reach = edgeFactorAt(p, thickness, invRefFactor) * DISP_CONST
			if maxScale > roomBase then
				-- Mirror the displacement bake's linear rescale into the fetch
				-- room: along the scan axis the point sits halfMin - p from the
				-- window center
				local room = halfMin - p + roomBase
				if maxScale > room then
					reach = reach * room / maxScale
				end
			end
			for channel = -1, 1 do
				local fetch = (p + reach * (1 + channel * spread)) * invDepthBin // 1
				if fetch < 0 then
					fetch = 0
				elseif fetch > DEMAND_BINS - 1 then
					fetch = DEMAND_BINS - 1
				end
				demand[fetch + 1] += weight
			end
		end
		smoothHistogram(demand)
	end

	-- Demand at a window point is the depth profile evaluated at the
	-- point's SDF depth. Outside the shape, depth <= 0, so this returns
	-- the dead-zone floor.
	local function demandAt(x: number, y: number): number
		local d = sdfRoundedRect(math.abs(x - halfW) - insetX, math.abs(y - halfH) - insetY, radius, n, invN)
		return sampleDemand(demand, -d * invDepthBin - 0.5)
	end

	-- Rows from the field's y marginal
	local marginalY = table.create(DEMAND_BINS, 0)
	local marginalStepX = winW / DEMAND_BINS
	local marginalStepY = halfH / DEMAND_BINS
	for by = 0, DEMAND_BINS - 1 do
		local y = (by + 0.5) * marginalStepY
		local sum = 0
		for bx = 0, DEMAND_BINS - 1 do
			sum += demandAt((bx + 0.5) * marginalStepX, y)
		end
		marginalY[by + 1] = sum / DEMAND_BINS
	end
	local positionsY = buffer.create(gridH * 4)
	local lutY = buffer.create(WARP_LUT_SIZE * 4)
	buildAxisFromDemand(marginalY, gridH, winH, maxDensity, positionsY, 0, lutY, 0)

	-- Each grid row's x warp from the field along that row: cells land where
	-- the band crosses the row, so the lattice follows the literal distance
	-- to the edge. Fixed cells-per-row cancels the row-mass normalization,
	-- keeping row density times conditional density proportional to the
	-- field.
	local positionsX = buffer.create(gridW * gridH * 4)
	local lutX = buffer.create(WARP_LUT_SIZE * gridH * 4)
	local slice = table.create(DEMAND_BINS, 0)
	local sliceStep = halfW / DEMAND_BINS
	for j = 0, gridH - 1 do
		local rowY = buffer.readf32(positionsY, j * 4)
		for bx = 1, DEMAND_BINS do
			slice[bx] = demandAt((bx - 0.5) * sliceStep, rowY)
		end
		buildAxisFromDemand(slice, gridW, winW, maxDensity, positionsX, j * gridW * 4, lutX, j * WARP_LUT_SIZE * 4)
	end

	return positionsX, lutX, positionsY, lutY
end

-- Linear interpolation into a warp LUT. idx is the extent position
-- already scaled to LUT index space. base is the entry offset of the LUT
-- block to read: 0 for the y LUT, a row multiple of WARP_LUT_SIZE for x
-- LUTs.
local function warpLookup(lut: buffer, base: number, idx: number): number
	if idx < 0 then
		idx = 0
	elseif idx > WARP_LUT_MAX then
		idx = WARP_LUT_MAX
	end
	local i0 = idx // 1
	local fraction = idx - i0
	local g0 = buffer.readf32(lut, (base + i0) * 4)
	local g1 = buffer.readf32(lut, (base + (if i0 < WARP_LUT_MAX then i0 + 1 else i0)) * 4)
	return g0 + (g1 - g0) * fraction
end
Warp.warpLookup = warpLookup

-- X lookup through the per-row conditional LUTs, interpolated between the
-- two grid rows adjacent to the fetch's continuous row coordinate gy. Row
-- cell centers come from the same per-row CDFs, so a cell center still maps
-- back to exactly its own index.
local function warpLookupX(lutX: buffer, gy: number, gridHm1: number, idx: number): number
	local j0 = gy // 1
	local fj = gy - j0
	if j0 >= gridHm1 then
		j0 = gridHm1
		fj = 0
	end
	local g0 = warpLookup(lutX, j0 * WARP_LUT_SIZE, idx)
	if fj <= 0 then
		return g0
	end
	return g0 + (warpLookup(lutX, (j0 + 1) * WARP_LUT_SIZE, idx) - g0) * fj
end
Warp.warpLookupX = warpLookupX

return Warp
