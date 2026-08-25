--!strict
--!native
--!optimize 2

-- Stage A: cached geometry bake. Cached per unique geometry; identical windows share buffers

local Shape = require(script.Parent.Shape)
local Refraction = require(script.Parent.Refraction)
local Types = require(script.Parent.Types)

type LiquidParams = Types.LiquidParams
type GeometryEntry = Types.GeometryEntry

local sdfRoundedRect = Shape.sdfRoundedRect
local deriveShape = Shape.deriveShape
local edgeFactorAt = Refraction.edgeFactorAt
local DISP_CONST = Refraction.DISP_CONST
local FETCH_ROOM = Refraction.FETCH_ROOM

-- Distance field uses melting contour family instead of raw field to remove corner creases
-- droplet look — with no anisotropy left to trace an X. Each pixel
-- solves for its own contour and takes that contour's depth and normal,
-- so one smooth scalar field drives magnitude and direction alike. A
-- circular window (r = H) stays exact at every depth. The span floor
-- keeps a barely-rounded window's melt from finishing in its first few
-- pixels of depth; its negative offset radius clamps to a sharp corner,
-- reproducing the sharp rim those windows actually have.
local MELT_SPAN_FLOOR = 0.25
local DISP_FIXED_SCALE = 16 -- Q11.4 fixed point: the i16 maps store displacement px * 16
local ROWS_PER_CLOCK_CHECK = 4 -- geometry build rows between deadline checks

local Geometry = {}

Geometry.DISP_FIXED_SCALE = DISP_FIXED_SCALE
Geometry.MELT_SPAN_FLOOR = MELT_SPAN_FLOOR

-- Rim falloff shared by the fresnel and glare bakes: a fifth-power ramp
-- over depth, 1 at the rim, fading toward the interior. k comes from
-- rimK below, and hardness raises the whole ramp. Negative depths (the
-- antialiased sliver outside the shape) clamp to 1.
local function rimFactor(depth: number, k: number, hardness: number): number
	local b = 1 + hardness - depth * k
	if b <= 0 then
		return 0
	end
	local b2 = b * b
	return math.min(b2 * b2 * b, 1)
end

-- Folds a rim size control into rimFactor's k coefficient, nil when the
-- size disables the effect. Both bakes read this one fold, so the
-- fresnel and glare ramps cannot drift apart.
local function rimK(size: number): number?
	return if size > 0 then (500 / size) ^ 2 / 1500 else nil
end

-- Every parameter the geometry build (buildSdfRows/buildDisplacementRows)
-- reads must appear in this key. A build input missing here would alias
-- geometry across windows through the cache. Chromatic aberration,
-- fresnel intensity, tint, and blur are render-time inputs, so the key
-- omits them. rawField is Config.DEBUG_RAW_DISTANCE_FIELD; it changes the
-- displacement bake, so it must not alias against melted builds either.
function Geometry.geometryKey(
	winW: number,
	winH: number,
	outW: number,
	outH: number,
	params: LiquidParams,
	rawField: boolean?
): string
	return (if rawField then "raw:" else "")
		.. string.format(
			"%d:%d:%d:%d:%.1f:%.2f:%.2f:%.3f:%.1f:%.3f:%.1f:%.3f:%.3f:%.3f:%.3f:%.4f",
			math.round(winW),
			math.round(winH),
			outW,
			outH,
			params.cornerRadius,
			params.superEllipseFactor,
			params.thickness,
			params.refractionFactor,
			params.fresnelSize,
			params.fresnelHardness,
			params.glareSize,
			params.glareHardness,
			params.glareIntensity,
			params.glareConvergence,
			params.glareOppositeSide,
			params.glareAngle
		)
end

-- Geometry depends only on (window size, output size, glass parameters), so
-- built maps are cached and refcounted.
local geometryCache: { [string]: GeometryEntry } = {}

-- key must be Geometry.geometryKey of the same arguments; the caller already
-- computes it to compare against its current entry.
function Geometry.acquireGeometry(
	winW: number,
	winH: number,
	outW: number,
	outH: number,
	params: LiquidParams,
	key: string,
	rawField: boolean?
): GeometryEntry
	local entry = geometryCache[key]
	if entry then
		entry.Refs += 1
		return entry
	end

	local pixelBytes = outW * outH * 4
	local newEntry: GeometryEntry = {
		Key = key,
		Refs = 1,
		Ready = false,
		WinW = winW,
		WinH = winH,
		OutW = outW,
		OutH = outH,
		StepX = winW / outW,
		StepY = winH / outH,
		DispMap = buffer.create(pixelBytes),
		AuxMap = buffer.create(pixelBytes),
		Phase = 1,
		Row = 0,
		Params = params,
		RawField = rawField == true,
	}
	geometryCache[key] = newEntry
	return newEntry
end

function Geometry.releaseGeometry(entry: GeometryEntry)
	entry.Refs -= 1
	if entry.Refs <= 0 then
		geometryCache[entry.Key] = nil
	end
end

-- Phase 1: signed distance, alpha coverage, and the baked fresnel
-- factor, all in window-pixel units at output resolution. These need
-- only the distance; everything that needs the normal waits for phase 2.
local function buildSdfRows(entry: GeometryEntry, deadline: number)
	local aux = entry.AuxMap
	local params = entry.Params
	local outW, outH = entry.OutW, entry.OutH
	local stepX, stepY = entry.StepX, entry.StepY
	local centerX, centerY, radius, insetX, insetY, n, invN = deriveShape(params, entry.WinW, entry.WinH)
	local fresnelHardness = params.fresnelHardness
	local fresnelK = rimK(params.fresnelSize)
	-- Mask coverage ramps over one output texel, centered on the true edge.
	-- The output texel is coarser than a window pixel, so a subtexel ramp
	-- would alias into a lumpy upscaled arc instead. The mask always
	-- includes the edge itself. Extending alpha past the shape, for a
	-- UICorner to cut, was tried and showed as a halo ring, because
	-- Roblox's clip boundary is not pixel-identical to this SDF.
	local invMaskStep = 1 / math.max(stepX, stepY)

	local row = entry.Row
	while row < outH do
		local py = (row + 0.5) * stepY - centerY
		local qy = math.abs(py) - insetY
		local rowOffset = row * outW * 4
		for x = 0, outW - 1 do
			local px = (x + 0.5) * stepX - centerX
			local qx = math.abs(px) - insetX
			local d = sdfRoundedRect(qx, qy, radius, n, invN)
			local depth = -d

			local offset = rowOffset + x * 4
			local fresnel = if fresnelK then rimFactor(depth, fresnelK, fresnelHardness) else 0
			buffer.writeu8(aux, offset, math.round(fresnel * 255))
			-- One-texel antialiased coverage of the shape
			buffer.writeu8(aux, offset + 2, math.round(math.clamp(0.5 - d * invMaskStep, 0, 1) * 255))
		end
		row += 1
		if row % ROWS_PER_CLOCK_CHECK == 0 and os.clock() >= deadline then
			break
		end
	end

	if row >= outH then
		entry.Phase = 2
		entry.Row = 0
	else
		entry.Row = row
	end
end

-- Phase 2: melting-contour depth and normals (see the MELT_SPAN_FLOOR
-- comment block) -> the refraction displacement and the baked glare
-- factor.
local function buildDisplacementRows(entry: GeometryEntry, deadline: number)
	local disp, aux = entry.DispMap, entry.AuxMap
	local params = entry.Params
	local rawField = entry.RawField
	local outW, outH = entry.OutW, entry.OutH
	local stepX, stepY = entry.StepX, entry.StepY
	local centerX, centerY, radius, insetX, insetY, n, invN = deriveShape(params, entry.WinW, entry.WinH)
	local halfMin = math.min(centerX, centerY)
	local invMeltSpan = 1 / math.max(radius, MELT_SPAN_FLOOR * halfMin)
	local thickness = params.thickness
	local invRefFactor = 1 / params.refractionFactor
	local glareHardness = params.glareHardness
	local glareK = rimK(params.glareSize)
	local glareIntensity = params.glareIntensity
	local glareOpposite = params.glareOppositeSide
	local glareExponent = 0.1 + params.glareConvergence * 2
	-- Offsets the normal's angle by -45 degrees before
	-- doubling, which puts the two lobes on the glare axis
	local glareAngleBias = params.glareAngle - math.pi / 4
	local twoPi = 2 * math.pi
	local room = FETCH_ROOM * halfMin
	-- The largest displacement the profile can ask for, at depth zero
	local maxScale = edgeFactorAt(0, thickness, invRefFactor) * DISP_CONST
	-- Depth beyond which the displacement and the glare are both exactly
	-- zero: the refracting band ends at the thickness, and the glare's
	-- rim ramp ends where 1 + hardness - depth * k reaches zero
	local zeroDepth = if glareK then math.max(thickness, (1 + glareHardness) / glareK) else thickness

	-- Signed position of the pixel (absPx, absPy, both quadrant-folded)
	-- against the family's contour at depth d: negative inside, positive
	-- outside. Also returns the contour-local corner offsets and the
	-- contour's superellipse exponent, for the normal branches below. The
	-- contours shrink as d grows, so this is increasing in d and the
	-- contour through a pixel is a bisection root.
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
		local qx = apx - (centerX - d - rho)
		local qy = apy - (centerY - d - rho)
		local g
		if qx > 0 and qy > 0 then
			g = (qx ^ m + qy ^ m) ^ (1 / m) - rho
		else
			g = (if qx > qy then qx else qy) - rho
		end
		return g, qx, qy, m
	end

	local row = entry.Row
	while row < outH do
		local rowBase = row * outW
		local py = (row + 0.5) * stepY - centerY
		local absPy = math.abs(py)
		local sy = if py >= 0 then 1 else -1
		for x = 0, outW - 1 do
			local offset = (rowBase + x) * 4
			-- Pixels the mask excludes entirely are never read:
			-- reconstruction writes them transparent without touching the
			-- displacement or glare, so their zeroed map bytes can stay
			if buffer.readu8(aux, offset + 2) == 0 then
				continue
			end
			local px = (x + 0.5) * stepX - centerX
			local absPx = math.abs(px)
			local sx = if px >= 0 then 1 else -1

			local depth: number, qx: number, qy: number, m: number
			if rawField then
				-- Debug: depth and normal straight from the distance field.
				-- The same normal branches below then produce the field's creased gradient,
				-- so the mirrored fold the melting contours remove renders literally.
				qx, qy, m = absPx - insetX, absPy - insetY, n
				depth = -sdfRoundedRect(qx, qy, radius, n, invN)
				if depth < 0 then
					depth = 0
				elseif depth > zeroDepth then
					continue
				end
			else
				-- Past zeroDepth the displacement and the glare are both
				-- exactly zero, so the contour solve below would only write
				-- zeros the maps already hold. The contour field is increasing
				-- in depth, so a negative value at zeroDepth means this pixel's
				-- own contour lies deeper still.
				if contourAt(absPx, absPy, zeroDepth) < 0 then
					continue
				end

				-- Solve for the contour through this pixel. Pixels in the
				-- antialiased sliver outside the shape stay at depth zero, on
				-- the exact rim contour.
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

			local dirX, dirY
			if qx > 0 and qy > 0 then
				-- Superellipse corner of the contour. The un-normalized
				-- gradient direction is the component-wise power, with the
				-- exponent eased toward a circle's as the contour melts.
				dirX = sx * qx ^ (m - 1)
				dirY = sy * qy ^ (m - 1)
			elseif qy >= qx then
				-- Beside the contour's straight top or bottom edge (on the
				-- contour, the larger offset sits exactly at the corner
				-- radius): the normal is exactly vertical, matching the
				-- corner branch's limit at qx = 0
				dirX = 0
				dirY = sy
			else
				dirX = sx
				dirY = 0
			end

			local len = math.sqrt(dirX * dirX + dirY * dirY)
			local dispX, dispY = 0, 0
			local glare = 0
			-- The direction length only vanishes at the exact window
			-- center, where the contour degenerates to a point and the
			-- displacement is negligible anyway.
			if len > 1e-9 then
				local invLen = 1 / len
				local nx, ny = dirX * invLen, dirY * invLen

				-- Displacement runs inward, against the outward normal,
				-- matching Apple's material: interior content near the edge
				-- is magnified and mirrored into the rim.
				local scale = edgeFactorAt(depth, thickness, invRefFactor) * DISP_CONST
				if maxScale > room then
					-- The profile can overshoot the window, so rescale it
					-- linearly into the room this pixel's fetch has: from
					-- the pixel through the window center to FETCH_ROOM of
					-- the half min axis beyond it. A linear fit keeps the
					-- profile injective along the ray; a saturating cap
					-- would pile every deep rim fetch onto one shell and
					-- smear it into streaks (see Refraction.FETCH_ROOM)
					local reach = px * nx + py * ny + room
					if maxScale > reach then
						scale = scale * reach / maxScale
					end
				end
				dispX = -nx * scale
				dispY = -ny * scale

				if glareK then
					local geo = rimFactor(depth, glareK, glareHardness)
					if geo > 0 then
						-- Two glare lobes from doubling the normal's angle: a
						-- bright one along the glare axis and a dimmer one
						-- opposite it, scaled by glareOppositeSide. The
						-- convergence exponent sharpens both. This buffer
						-- is y-down, so the normal's y flips here to
						-- keep the same GlareAngle pointing the same way on
						-- screen.
						local angle = math.atan2(-ny, nx)
						if angle < 0 then
							angle += twoPi
						end
						local a = (angle + glareAngleBias) * 2
						local farside = (a > 1.5 * math.pi and a < 3.5 * math.pi) or a < -0.5 * math.pi
						local af = (0.5 + math.sin(a) * 0.5)
							* 1.2
							* (if farside then glareOpposite else 1)
							* glareIntensity
						glare = math.clamp(af ^ glareExponent, 0, 1) * geo
					end
				end
			end

			buffer.writei16(disp, offset, math.clamp(math.round(dispX * DISP_FIXED_SCALE), -32767, 32767))
			buffer.writei16(disp, offset + 2, math.clamp(math.round(dispY * DISP_FIXED_SCALE), -32767, 32767))
			buffer.writeu8(aux, offset + 1, math.round(glare * 255))
		end
		row += 1
		if row % ROWS_PER_CLOCK_CHECK == 0 and os.clock() >= deadline then
			break
		end
	end

	if row >= outH then
		entry.Phase = 3
	else
		entry.Row = row
	end
end

-- Advances a chunked geometry build until the deadline (an os.clock() time;
-- pass math.huge to build synchronously). Returns true once the maps are
-- complete.
function Geometry.stepGeometry(entry: GeometryEntry, deadline: number): boolean
	if entry.Ready then
		return true
	end
	if entry.Phase == 1 then
		buildSdfRows(entry, deadline)
	end
	if entry.Phase == 2 and os.clock() < deadline then
		buildDisplacementRows(entry, deadline)
	end
	if entry.Phase == 3 then
		entry.Ready = true
	end
	return entry.Ready
end

return Geometry
