repeat task.wait(1) until game:IsLoaded()

local Promise = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Promise"))
local replaySystem = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("modules"):WaitForChild("ReplaySystem")

replaySystem = require(replaySystem)


replaySystem:init()

print("Loaded")