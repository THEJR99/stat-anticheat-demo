local Promise = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Promise"))

local CaptureRemote: RemoteEvent = game:GetService("ReplicatedStorage"):WaitForChild("Remotes"):WaitForChild("Other"):WaitForChild("ReplayCapture")

local HTTP = game:GetService("HttpService")
local Players = game:GetService("Players")

-- SETTINGS
local SAMPLE_INTERVAL_PER_SECOND = 10 -- How often to sample HRP data (in seconds)

-- SERVER METADATA
local serverSession = {
    logVersion = 0.01,
    serverId = game.JobId,
    sessionStartTimeEpoch = os.time(), -- epoch timestamp (Server Start Time)
    sampleRate = SAMPLE_INTERVAL_PER_SECOND,
    _logStartTime = 0,
    joinLeaveLog = {},    -- array of { userId = number, time = os.time(), action = "join"/"leave" }
    --playerAliasLog = {},  -- gives each player a alias/number for sake of data storage later --
    movementLog = {},
}

local configs = {
    captureEnabled = false,           -- [userId] = { { time = t, hrpPosition = Vector3, hrpRotation = Vector3 }, ... }
    capturePromise = nil
}

local systemData = {
    CurrentTime = 0
}

local function serializeVectors(data)
	local function convert(value)
		if typeof(value) == "Vector3" then
			return { value.X, value.Y, value.Z }
		elseif typeof(value) == "table" then
			local result = {}
			for k, v in pairs(value) do
				result[k] = convert(v)
			end
			return result
		else
			return value
		end
	end

	return convert(data)
end

local function PositionCapturePromise()
    print("Server-wide capture started")

    return Promise.new(function(resolve, _, onCancel)
        local enabled = true
        local logCount = 0

        local function displayResults()
            print('Sample Collected! Total logs: ' .. tostring(logCount))
            serverSession.joinLeaveLog =  serializeVectors(serverSession.joinLeaveLog)
            serverSession.movementLog =   serializeVectors(serverSession.movementLog)

            local toJson = serverSession
            toJson = serializeVectors(serverSession)


            local sessionLog = HTTP:JSONEncode(toJson)

            print("Replay Log Complete:\n\n\n\n" .. sessionLog)
        end

        local function cancel()
            enabled = false
            print("Server-Wide Capture Ended")

            displayResults()
        end

        onCancel(cancel)

        systemData.CurrentTime = os.clock()
        serverSession._logStartTime = systemData.CurrentTime

        local function LogInitalPlayerPosRot()
            local logData = {time = systemData.CurrentTime}

            for _, player in pairs(Players:GetPlayers()) do
                local character = player.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")
                if not hrp then continue end

                logData[player.UserId] = {
                    hrpPosition = hrp.Position,
                    hrpRotation = hrp.Orientation
                }
            end

            table.insert(serverSession.movementLog, logData)
        end

        LogInitalPlayerPosRot()

        while enabled do
            systemData.CurrentTime = os.clock()
            local logData = {time = systemData.CurrentTime}

            for _, player in pairs(Players:GetPlayers()) do
                local character = player.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")
                if not hrp then continue end

                logData[player.UserId] = {
                    hrpPosition = hrp.Position,
                    hrpRotation = hrp.Orientation
                }
            end

            table.insert(serverSession.movementLog, logData)

            logCount += 1
            task.wait(1/SAMPLE_INTERVAL_PER_SECOND)
        end

        resolve()
    end)
end


-- JOIN/LEAVE TRACKING
local function handlePlayerAdded(player)
    table.insert(serverSession.joinLeaveLog, {
        userId = player.UserId,
        time = systemData.CurrentTime,
        action = "join"
    })

    serverSession.movementLog[player.UserId] = {}
end

local function handlePlayerRemoving(player)
    table.insert(serverSession.joinLeaveLog, {
        userId = player.UserId,
        time = systemData.CurrentTime,
        action = "leave"
    })
end


local function handleCaptureEvent(player, start)
    local enabled = configs.captureEnabled
    if enabled == start then warn("Same input detected! Ignoring..") return end

    if not start then
        configs.capturePromise:cancel()
        configs.captureEnabled = false
        return
    end

    print("Starting new Server-Wide capture")
    configs.captureEnabled = true
    configs.capturePromise = PositionCapturePromise()
end

Players.PlayerAdded:Connect(handlePlayerAdded)
Players.PlayerRemoving:Connect(handlePlayerRemoving)
CaptureRemote.OnServerEvent:Connect(handleCaptureEvent)









