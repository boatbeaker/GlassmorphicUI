--[[
	Tests for the reconstruction row range. The parallel route hands each
	worker a band of rows through Row/RowEnd, so reconstructing a pass as
	several disjoint ranges must produce byte-identical output to one full
	pass — over real warp and geometry maps, since the row math reads both.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")
local TestProject = ReplicatedStorage:WaitForChild("TestProject")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Helpers = require(TestProject:WaitForChild("helpers"))
local library = Helpers.resolveLibrary()

local Liquid = require(library:WaitForChild("Liquid")) :: any
local Config = require(library:WaitForChild("Config")) :: any

local WIN_W, WIN_H = 64, 48
local OUT_W, OUT_H = 64, 48
local GRID_W, GRID_H = 16, 12

-- Hand-built normalized parameters (the shape Attributes.parseLiquidParams
-- produces), with dispersion on so the per-channel fetch path runs too.
local params = {
	cornerRadius = 10,
	superEllipseFactor = 3,
	thickness = 8,
	refractionFactor = 2.1,
	chromaticAberration = 0.2,
	fresnelSize = 4,
	fresnelHardness = 0.4,
	fresnelIntensity = 0.25,
	glareSize = 8,
	glareHardness = 0.4,
	glareIntensity = 0.7,
	glareConvergence = 0.9,
	glareOppositeSide = 0.5,
	glareAngle = -0.87,
	maxOutputResolution = 64,
}

local function buildJob(tintAlpha: number): { [string]: any }
	local _gridPosX, warpLutX, _gridPosY, warpLutY =
		Liquid.buildWarp(GRID_W, GRID_H, WIN_W, WIN_H, params, Config.EDGE_DENSITY_BOOST)

	local key = Liquid.geometryKey(WIN_W, WIN_H, OUT_W, OUT_H, params)
	local geometry = Liquid.acquireGeometry(WIN_W, WIN_H, OUT_W, OUT_H, params, key)
	if not geometry.Ready then
		Liquid.stepGeometry(geometry, math.huge)
	end

	local grid = Helpers.makeBuffer(GRID_W, GRID_H, Helpers.patternFill)
	local redScale, blueScale = Liquid.dispersionScales(params.chromaticAberration)

	return {
		Out = buffer.create(OUT_W * OUT_H * 4),
		Disp = geometry.DispMap,
		Aux = geometry.AuxMap,
		Grid = grid,
		GridW = GRID_W,
		GridH = GRID_H,
		OutW = OUT_W,
		OutH = OUT_H,
		StepX = geometry.StepX,
		StepY = geometry.StepY,
		WarpX = warpLutX,
		WarpY = warpLutY,
		TintR = 0.78,
		TintG = 0.86,
		TintB = 0.96,
		TintAlpha = tintAlpha,
		RedScale = redScale,
		BlueScale = blueScale,
		BlurSigma = 0,
		FresnelIntensity = 0,
		RimEnabled = false,
		Row = 0,
		RowEnd = OUT_H,
		Geometry = geometry, -- kept so the test can release it
	}
end

local function releaseJob(job: { [string]: any })
	Liquid.releaseGeometry(job.Geometry)
end

-- Uneven on purpose: a one-row band, and boundaries that do not divide
-- the height evenly.
local BANDS = { 0, 10, 11, 30, OUT_H }

describe("reconstructRows row ranges", function()
	it("Banded ranges match one full pass byte for byte", function()
		local fullJob = buildJob(0.15)
		expect(Liquid.reconstructRows(fullJob, math.huge)).toBe(true)

		local bandedJob = buildJob(0.15)
		for index = 1, #BANDS - 1 do
			bandedJob.Row = BANDS[index]
			bandedJob.RowEnd = BANDS[index + 1]
			expect(Liquid.reconstructRows(bandedJob, math.huge)).toBe(true)
		end

		expect(Helpers.maxDifference(bandedJob.Out, fullJob.Out)).toBe(0)
		releaseJob(fullJob)
		releaseJob(bandedJob)
	end)

	it("Banded ranges match on the opaque short-circuit too", function()
		local fullJob = buildJob(1)
		expect(Liquid.reconstructRows(fullJob, math.huge)).toBe(true)

		local bandedJob = buildJob(1)
		for index = 1, #BANDS - 1 do
			bandedJob.Row = BANDS[index]
			bandedJob.RowEnd = BANDS[index + 1]
			expect(Liquid.reconstructRows(bandedJob, math.huge)).toBe(true)
		end

		expect(Helpers.maxDifference(bandedJob.Out, fullJob.Out)).toBe(0)
		releaseJob(fullJob)
		releaseJob(bandedJob)
	end)

	it("Reports an unfinished range and resumes it", function()
		local job = buildJob(0.15)
		job.RowEnd = 20
		expect(Liquid.reconstructRows(job, math.huge)).toBe(true)
		expect(job.Row).toBe(20)

		job.RowEnd = OUT_H
		expect(Liquid.reconstructRows(job, math.huge)).toBe(true)
		expect(job.Row).toBe(OUT_H)
		releaseJob(job)
	end)
end)
