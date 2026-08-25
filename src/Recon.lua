--!strict
--!native
--!optimize 2

-- Stages C-F: snapshot grid, reconstruct, frost, rim-shade, upload. Runs sync or parallel depending on load

local AssetService = game:GetService("AssetService")

local Liquid = require(script.Parent.Liquid)
local Config = require(script.Parent.Config)
local Composite = require(script.Parent.Composite)
local Dependencies = require(script.Parent.Dependencies)
local Layout = require(script.Parent.Layout)
local Parallel = require(script.Parent.Parallel)
local GlassObject = require(script.Parent.GlassObject)

type GlassObject = GlassObject.GlassObject

local EditableImageBlur = Dependencies.EditableImageBlur

local function ensureEditableImage(glassObject: GlassObject, resolution: Vector2): EditableImage?
	local existing = glassObject.EditableImage
	if existing and existing.Size == resolution then
		return existing
	end

	local function tryCreate()
		return pcall(AssetService.CreateEditableImage, AssetService, {
			Size = resolution,
		})
	end
	local success, editableImage = tryCreate()
	if (not success or not editableImage) and existing then
		-- Old image may have exhausted budget; free and retry
		existing:Destroy()
		glassObject.EditableImage = nil
		existing = nil
		success, editableImage = tryCreate()
	end
	if not success or not editableImage then
		-- Out of editable memory budget; retry on next write
		if not glassObject.WarnedImageCreateFailure then
			glassObject.WarnedImageCreateFailure = true
			warn(
				"GlassmorphicUI could not create an EditableImage:",
				if success then "budget exhausted" else editableImage
			)
		end
		return nil
	end
	glassObject.WarnedImageCreateFailure = false

	if existing then
		existing:Destroy()
	end
	glassObject.EditableImage = editableImage
	glassObject.Pane.ImageContent = Content.fromObject(editableImage)

	return editableImage
end

-- Builds immutable field set for reconstruction pass; captures everything so mid-pass changes don't affect output
local function makeJob(glassObject: GlassObject, grid: buffer): Liquid.ReconJob?
	local geometry = glassObject.Geometry
	local params = glassObject.LiquidParams
	local outPixels = glassObject.OutPixels
	local warpLutX, warpLutY = glassObject.WarpLutX, glassObject.WarpLutY
	if not geometry or not geometry.Ready or not params or not outPixels or not warpLutX or not warpLutY then
		return nil
	end

	local resolution = glassObject.Resolution
	local WindowColor = glassObject.WindowColor
	local outW, outH = glassObject.OutputResolution.X, glassObject.OutputResolution.Y
	local redScale, blueScale = Liquid.dispersionScales(params.chromaticAberration)
	return {
		Out = outPixels,
		Disp = geometry.DispMap,
		Aux = geometry.AuxMap,
		Grid = grid,
		GridW = resolution.X,
		GridH = resolution.Y,
		OutW = outW,
		OutH = outH,
		StepX = geometry.StepX,
		StepY = geometry.StepY,
		WarpX = warpLutX,
		WarpY = warpLutY,
		TintR = WindowColor[1],
		TintG = WindowColor[2],
		TintB = WindowColor[3],
		TintAlpha = WindowColor[4],
		RedScale = redScale,
		BlueScale = blueScale,
		-- Blur is in window px; output is downsampled, so sigma scales by step
		BlurSigma = math.min((glassObject.BlurRadius / 3) / geometry.StepX, math.max(outW, outH) / 2),
		FresnelIntensity = params.fresnelIntensity,
		RimEnabled = (params.fresnelSize > 0 and params.fresnelIntensity > 0)
			or (params.glareSize > 0 and params.glareIntensity > 0),
		-- Debug flag; disables parallel route since worker jobs don't carry it
		BilinearFetch = Config.DEBUG_BILINEAR_FETCH,
		Row = 0,
		RowEnd = outH,
	}
end

-- Stages C-D: snapshot grid, prep reconstruction pass over copy to avoid tearing
local function startRecon(glassObject: GlassObject): boolean
	local job = makeJob(glassObject, glassObject.Scratch)
	if not job then
		return false
	end
	-- Opaque tint: skip snapshot copy
	if not GlassObject.isOpaque(glassObject) then
		debug.profilebegin("GlassSnapshot")
		buffer.copy(glassObject.Scratch, 0, glassObject.Pixels)
		debug.profileend()
	end
	glassObject.ReconJob = job
	glassObject.ForceRecon = false
	glassObject.GridWritesSinceRecon = 0
	glassObject.FramesSinceRecon = 0

	if Config.DEBUG_SAMPLING_HEATMAP then
		-- Debug: render sampler density allocation instead of glass
		Liquid.renderDensityHeatmap(job)
	elseif Config.DEBUG_OVERLAY == "grid-view" or Config.DEBUG_OVERLAY == "grid-view-flat" then
		-- Debug: render source grid instead
		Liquid.renderGridView(job, glassObject.PixelIndex // 4, Config.DEBUG_OVERLAY == "grid-view")
	end
	if Config.DEBUG_OVERLAY == "grid-view" or Config.DEBUG_OVERLAY == "melt-contours" then
		-- Animated views re-render on wall clock; force passes for static backdrop
		glassObject.ForceRecon = true
	end
	return true
end

-- Write pixels to pane, step down resolution if image create fails
local function upload(glassObject: GlassObject, outPixels: buffer)
	debug.profilebegin("GlassUpload")
	local editableImage = ensureEditableImage(glassObject, glassObject.OutputResolution)
	if editableImage then
		editableImage:WritePixelsBuffer(Vector2.zero, glassObject.OutputResolution, outPixels)
	else
		Layout.stepDownResolution(glassObject)
		-- Retry without new grid writes; static backdrop stops writing once converged
		glassObject.ForceRecon = true
	end
	debug.profileend()
end

-- Apply debug overlay on top of finished glass; full-replacement views render in startRecon
local function applyDebugOverlay(glassObject: GlassObject, job: Liquid.ReconJob)
	local overlay = Config.DEBUG_OVERLAY
	local params = glassObject.LiquidParams
	if not overlay or not params then
		return
	end
	if overlay == "sdf-contours" or overlay == "melt-contours" then
		Liquid.drawContourOverlay(job, params, overlay == "melt-contours")
	elseif overlay == "normals" then
		Liquid.drawNormalOverlay(job, params, Config.DEBUG_RAW_DISTANCE_FIELD)
	elseif overlay == "cell-centers" or overlay == "cell-centers-uniform" then
		local gridPosX, gridPosY = glassObject.GridPosX, glassObject.GridPosY
		if gridPosX and gridPosY then
			Liquid.drawCellCenterOverlay(job, gridPosX, gridPosY, overlay == "cell-centers-uniform")
		end
	end
end

-- Stages E-F plus upload; runs when sync pass completes using synchronous Blur inside Heartbeat
local function finishRecon(glassObject: GlassObject, job: Liquid.ReconJob)
	glassObject.ReconJob = nil
	if
		not (
			Config.DEBUG_SAMPLING_HEATMAP
			or Config.DEBUG_OVERLAY == "grid-view"
			or Config.DEBUG_OVERLAY == "grid-view-flat"
		)
	then
		glassObject.OutBlend = Composite.run(job, EditableImageBlur.Blur, glassObject.OutBlend)
		applyDebugOverlay(glassObject, job)
	end
	upload(glassObject, job.Out)
end

-- The frost blur for the parallel route: EditableImageBlur.BlurAsync
-- spreads the blur across its own actor pool as halo-padded row bands,
-- yielding until they return, and falls back to its synchronous kernel
-- for small images or when its pool cannot run.
local function blurOnPool(config: { pixelBuffer: buffer, width: number, height: number, blurRadius: number })
	EditableImageBlur.BlurAsync({
		pixelBuffer = config.pixelBuffer,
		width = config.width,
		height = config.height,
		blurRadius = config.blurRadius,
		workerCount = Config.FROST_WORKER_COUNT,
	})
end

-- Stages E and F plus the upload for a gathered parallel pass, in their
-- own thread because the frost's BlurAsync yields while the blur pool
-- runs. The token guards the upload: a relayout, a total update, and
-- window removal each clear it, so a finish that raced one of those
-- drops its pixels instead of uploading over fresher state. The scrapped
-- output buffer needs no cleanup; every pass rewrites every row.
local function finishParallel(glassObject: GlassObject, job: Liquid.ReconJob)
	local token = {}
	glassObject.FinishToken = token
	task.spawn(function()
		-- No writes to glassObject until the token check passes: a removed
		-- window's record is cleared and frozen, where reads return nil
		-- but a write would throw
		local blendScratch = Composite.run(job, blurOnPool, glassObject.OutBlend)
		if glassObject.FinishToken ~= token then
			return
		end
		glassObject.OutBlend = blendScratch
		glassObject.FinishToken = nil
		upload(glassObject, job.Out)
	end)
end

local Recon = {}

-- Advances reconstruction under the deadline (math.huge means a full
-- synchronous pass). Polls an in-flight banded pass first, then resumes
-- an in-flight synchronous pass. Otherwise starts a fresh pass when
-- startIfIdle is true: across the worker pool when the dispatcher takes
-- it, else chunked on the main thread. Either route ends in upload.
function Recon.advance(glassObject: GlassObject, deadline: number, startIfIdle: boolean)
	-- A finish thread owns the output while it runs; starting or resuming
	-- anything here would race it
	if glassObject.FinishToken then
		return
	end

	local pending = glassObject.ParallelJob
	if pending then
		-- Splices arrived chunks into the output and drip-feeds each
		-- worker its next chunk
		debug.profilebegin("GlassGather")
		local status = Parallel.poll(glassObject, pending)
		debug.profileend()
		if status == "pending" then
			return
		end
		glassObject.ParallelJob = nil
		if status == "done" then
			finishParallel(glassObject, pending.Job)
		else
			-- The next advance re-renders synchronously what the workers
			-- failed to deliver
			glassObject.ForceRecon = true
		end
		return
	end

	local job = glassObject.ReconJob
	if not job then
		if not startIfIdle then
			return
		end
		-- A full synchronous update must finish within this call, so it
		-- never scatters
		if deadline ~= math.huge and Parallel.shouldUse(glassObject) then
			-- SendMessage copies the buffers it is handed, so that copy is
			-- this pass's snapshot, standing in for the Scratch copy the
			-- synchronous route makes
			local parallelJob = makeJob(glassObject, glassObject.Pixels)
			if parallelJob then
				debug.profilebegin("GlassScatter")
				local newPending = Parallel.scatter(glassObject, parallelJob)
				debug.profileend()
				if newPending then
					glassObject.ParallelJob = newPending
					glassObject.ForceRecon = false
					glassObject.GridWritesSinceRecon = 0
					glassObject.FramesSinceRecon = 0
					return
				end
			end
		end
		if not startRecon(glassObject) then
			return
		end
		job = glassObject.ReconJob
	end
	if job then
		debug.profilebegin("GlassReconstruct")
		local completed = Liquid.reconstructRows(job, deadline)
		debug.profileend()
		if completed then
			finishRecon(glassObject, job)
		end
	end
end

return Recon
