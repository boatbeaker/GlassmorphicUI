--[[
	Property tests for the frost pass. These pin the behaviors the
	refactor onto the ReconJob snapshot must preserve: the below-minimum
	skip, uniform-image exactness, mask and clear-value restoration, real
	smoothing at an edge, and blend-scratch reuse.
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
local Config = require(library:WaitForChild("Config")) :: any
local EditableImageBlur = require(library:WaitForChild("Packages"):WaitForChild("EditableImageBlur")) :: any

local Blur = EditableImageBlur.Blur

-- A fully-covered opaque image: mask 255 everywhere, alpha 255 everywhere.
local function makeCoveredImage(
	size: number,
	fillFn: (x: number, y: number) -> (number, number, number)
): (buffer, buffer)
	local out = Helpers.makeBuffer(size, size, function(x, y)
		local r, g, b = fillFn(x, y)
		return r, g, b, 255
	end)
	local aux = Helpers.makeAux(size, size, function()
		return 0, 0, 255
	end)
	return out, aux
end

describe("frost", function()
	it("Skips sigmas below the minimum and passes the scratch through", function()
		local out, aux = makeCoveredImage(8, Helpers.patternFill)
		local expected = Helpers.clone(out)
		local scratch = buffer.create(16)

		local job = Helpers.makeFinishJob({
			out = out,
			aux = aux,
			outW = 8,
			outH = 8,
			blurSigma = Config.MIN_BLUR_SIGMA / 2,
		})
		local returned = Frost.apply(job, Blur, scratch)

		expect(Helpers.maxDifference(out, expected)).toBe(0)
		expect(returned).toBe(scratch)
	end)

	it("Keeps a uniform opaque image exactly uniform", function()
		local out, aux = makeCoveredImage(16, function()
			return 128, 64, 200
		end)
		local expected = Helpers.clone(out)

		local job = Helpers.makeFinishJob({ out = out, aux = aux, outW = 16, outH = 16, blurSigma = 3 })
		Frost.apply(job, Blur, nil)

		expect(Helpers.maxDifference(out, expected)).toBe(0)
	end)

	it("Smooths a step edge", function()
		local size = 16
		local out, aux = makeCoveredImage(size, function(x)
			local value = if x < size / 2 then 0 else 255
			return value, value, value
		end)

		local job = Helpers.makeFinishJob({ out = out, aux = aux, outW = size, outH = size, blurSigma = 2 })
		Frost.apply(job, Blur, nil)

		local row = 8
		expect(Helpers.channelAt(out, size, 7, row, 0)).toBeGreaterThan(0)
		expect(Helpers.channelAt(out, size, 8, row, 0)).toBeLessThan(255)
	end)

	it("Restores the mask alpha and writes the clear value outside the mask", function()
		local size = 16
		-- Left half covered, right half outside the mask.
		local out = Helpers.makeBuffer(size, size, function(x, y)
			local r, g, b = Helpers.patternFill(x, y)
			return r, g, b, if x < size / 2 then 255 else 0
		end)
		local aux = Helpers.makeAux(size, size, function(x)
			return 0, 0, if x < size / 2 then 255 else 0
		end)

		local tintR, tintG, tintB = 0.25, 0.5, 0.75
		local job = Helpers.makeFinishJob({
			out = out,
			aux = aux,
			outW = size,
			outH = size,
			tintR = tintR,
			tintG = tintG,
			tintB = tintB,
			blurSigma = 2,
		})
		Frost.apply(job, Blur, nil)

		local clearValue = Liquid.clearColor(tintR, tintG, tintB)
		for y = 0, size - 1 do
			expect(Helpers.channelAt(out, size, 2, y, 3)).toBe(255)
			expect(buffer.readu32(out, (y * size + size - 2) * 4)).toBe(clearValue)
		end
	end)

	it("Reuses the blend scratch across calls", function()
		local size = 16
		local out, aux = makeCoveredImage(size, Helpers.patternFill)

		-- Sigma 2 has variance between the kernel's discrete levels, so the
		-- residual mix runs and the frost needs its scratch.
		local job = Helpers.makeFinishJob({ out = out, aux = aux, outW = size, outH = size, blurSigma = 2 })
		local scratch = Frost.apply(job, Blur, nil)
		expect(scratch).never.toBeNil()
		expect(buffer.len(scratch :: buffer)).toBe(size * size * 4)

		local secondScratch = Frost.apply(job, Blur, scratch)
		expect(secondScratch).toBe(scratch)
	end)
end)
