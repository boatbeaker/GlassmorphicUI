--[[
	Boots Jest inside the built test place. run-in-roblox reports the place
	script's outcome, so failing tests surface by erroring at the end.
]]

-- run-in-roblox output does not render ANSI colors, so Jest's reporter
-- prints plain text.
-- selene: allow(global_usage)
_G.NOCOLOR = true

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")
local TestProject = ReplicatedStorage:WaitForChild("TestProject")

local Jest = require(DevPackages:WaitForChild("Jest"))

local runCLIOptions = {
	verbose = true,
	ci = false,
}

local projects = {
	TestProject,
}

local status, result = Jest.runCLI(script, runCLIOptions, projects):awaitStatus()

-- run-in-roblox can drop log output that is still queued when the place
-- closes, so give it a moment to drain before returning.
task.wait(2)

-- Jest resolves whether or not the tests passed, so failure has to be read
-- out of the run results. Erroring here is what makes run-in-roblox hand a
-- nonzero exit code back to scripts/test.sh.
if status ~= "Resolved" then
	error(`Jest did not complete: {tostring(result)}`)
end

local runResults = result.results

-- Jest already rejects a project that matches zero test files, so this
-- guard exists for config drift that would make an empty run resolve, like
-- a future passWithNoTests option; zero discovered tests must still fail.
if runResults.numTotalTests == 0 then
	error("Jest discovered zero tests, so the run proves nothing")
end

if runResults.numFailedTestSuites > 0 or runResults.numFailedTests > 0 then
	error(`{runResults.numFailedTests} failed tests across {runResults.numFailedTestSuites} failed suites`)
end

return nil
