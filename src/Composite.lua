--!strict
--!native
--!optimize 2

-- Stages E and F: frost blur, then rim shading. Runs inline on sync route, in finish thread on parallel route

local Liquid = require(script.Parent.Liquid)
local Frost = require(script.Parent.Frost)

local Composite = {}

-- blur is injected from caller; blendScratch is reused frost buffer
function Composite.run(job: Liquid.ReconJob, blur: Frost.BlurFunction, blendScratch: buffer?): buffer?
	-- Solid tint is already flat; skip frost blur
	if job.TintAlpha < 1 then
		blendScratch = Frost.apply(job, blur, blendScratch)
	end
	-- Rim shading composites after frost to keep fresnel and glare sharp
	if job.RimEnabled then
		debug.profilebegin("GlassRim")
		Liquid.compositeRim(job.Out, job.Aux, job.OutW * job.OutH, job.FresnelIntensity)
		debug.profileend()
	end
	return blendScratch
end

return Composite
