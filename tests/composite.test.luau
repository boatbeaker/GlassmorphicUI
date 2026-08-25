--[[
	Tests for the shared finish stage. Composite.run must route exactly
	like the orchestrator's old finish sequence did: frost only when the
	tint lets the backdrop through, rim only when a rim term is enabled,
	rim composited after the frost.
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
local Frost = require(library:WaitForChild("Frost")) :: any
local Composite = require(library:WaitForChild("Composite")) :: any
local EditableImageBlur = require(library:WaitForChild("Packages"):WaitForChild("EditableImageBlur")) :: any

local Blur = EditableImageBlur.Blur

local SIZE = 16

-- A patterned, fully-covered image with rim bytes in the aux map.
local function makeImage(): (buffer, buffer)
	local out = Helpers.makeBuffer(SIZE, SIZE, function(x, y)
		local r, g, b = Helpers.patternFill(x, y)
		return r, g, b, 255
	end)
	local aux = Helpers.makeAux(SIZE, SIZE, function(x, y)
		return (x * 17) % 256, (y * 23) % 256, 255
	end)
	return out, aux
end

local function makeJob(out: buffer, aux: buffer, overrides: { [string]: any })
	local options = {
		out = out,
		aux = aux,
		outW = SIZE,
		outH = SIZE,
		blurSigma = 2,
		fresnelIntensity = 0.6,
	}
	for key, value in overrides do
		options[key] = value
	end
	return Helpers.makeFinishJob(options)
end

describe("composite", function()
	it("Skips the frost at full tint alpha", function()
		local out, aux = makeImage()
		local expected = Helpers.clone(out)

		local job = makeJob(out, aux, { tintAlpha = 1 })
		local scratch = Composite.run(job, Blur, nil)

		expect(Helpers.maxDifference(out, expected)).toBe(0)
		expect(scratch).toBeNil()
	end)

	it("Matches frost alone when the rim is disabled", function()
		local out, aux = makeImage()
		local reference = Helpers.clone(out)

		Composite.run(makeJob(out, aux, {}), Blur, nil)
		Frost.apply(makeJob(reference, aux, {}), Blur, nil)

		expect(Helpers.maxDifference(out, reference)).toBe(0)
	end)

	it("Matches frost then rim when the rim is enabled", function()
		local out, aux = makeImage()
		local reference = Helpers.clone(out)

		local fresnelIntensity = 0.6
		Composite.run(makeJob(out, aux, { rimEnabled = true }), Blur, nil)

		-- The old finish sequence: frost, then the rim composite over it.
		Frost.apply(makeJob(reference, aux, {}), Blur, nil)
		Liquid.compositeRim(reference, aux, SIZE * SIZE, fresnelIntensity)

		expect(Helpers.maxDifference(out, reference)).toBe(0)
	end)

	it("Returns the frost's blend scratch for reuse", function()
		local out, aux = makeImage()

		local scratch = Composite.run(makeJob(out, aux, {}), Blur, nil)
		expect(scratch).never.toBeNil()

		local secondScratch = Composite.run(makeJob(out, aux, {}), Blur, scratch)
		expect(secondScratch).toBe(scratch)
	end)
end)
