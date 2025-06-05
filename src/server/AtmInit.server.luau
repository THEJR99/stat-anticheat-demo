local RS = game:GetService("ReplicatedStorage")
local HackEvent = RS:WaitForChild("Remotes"):WaitForChild("ATM"):WaitForChild("StartATMMinigame")

local atms = workspace:WaitForChild("Atms"):GetChildren()

print("Atms are:")
print(atms)

for _, atmObject in pairs(atms) do
    local prompt = atmObject.ProximityPrompt

    prompt.Triggered:Connect(function(player)
	    HackEvent:FireClient(player)
    end)
end