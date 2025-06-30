repeat task.wait(1) until game:IsLoaded()

local replaySystem = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("modules"):WaitForChild("ReplaySystem")

replaySystem = require(replaySystem)


replaySystem:init()

print("Loaded")