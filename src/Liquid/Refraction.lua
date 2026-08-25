--!strict
--!native
--!optimize 2

-- 1D refraction profile: fetch distance for pixel depth. Both geometry bake and warp scan use identical physics

local Refraction = {}

-- Displacement scale in px per edge factor; resolution-independent constant
Refraction.DISP_CONST = 0.05 * math.sqrt(2) * 1000

-- Soft-cap displacement to room available; small windows mirror their interior
Refraction.FETCH_ROOM = 0.9

-- Refraction edge factor at depth d; returns 0 at thickness for fused path
function Refraction.edgeFactorAt(d: number, thickness: number, invRefFactor: number): number
	if d < 0 or d >= thickness then
		return 0
	end
	local x = 1 - d / thickness
	local sinI = x * x -- in [0, 1], so the asin calls stay in domain
	local thetaI = math.asin(sinI)
	local thetaT = math.asin(sinI * invRefFactor)
	return math.tan(thetaI - thetaT)
end

-- Per-channel displacement multipliers for chromatic aberration; green is 1
function Refraction.dispersionScales(aberration: number): (number, number)
	return 1 + aberration, 1 - aberration
end

return Refraction
