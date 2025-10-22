local Promise = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Promise"))
local HTTP = game:GetService("HttpService")

local CaptureRemote: RemoteEvent = game:GetService("ReplicatedStorage"):WaitForChild("Remotes"):WaitForChild("Other"):WaitForChild("ReplayCapture")
local Players = game:GetService('Players')

local Capture = {}

local Config = {
    ReplaySampleRate = 10,
    UploadChunkSize = 600, -- Frames needed to upload
}

local Connections = {
    Join = nil,
    Leave = nil,
}

local RuntimeData = {
    CurrentTime = 0,
    CaptureEnabled = false,
    CapturePromise = nil,
    ConnectedAliasList = {}, -- UserId : Alias
    JoinLeaveCountOnLastSave = 0,
}

local TempSession = {}

local serverSession = {
    logVersion = 0.01,
    serverId = game.JobId,
    sessionStartTimeEpoch = os.time(), -- epoch timestamp (Server Start Time)
    sampleRate = Config.ReplaySampleRate,
    frame_count = 0,
    chunk_count = 0,
    log_start_time = 0,
    joinLeaveLog = {},    -- array of { alias = string, time = os.time(), action = "join"/"leave" }
    joinLeaveEventCount = 0,
    alias_log = {},  -- UserId : Alias | gives each player a alias/number for sake of data storage later --
    total_session_player_count = 0,
    movementLog = {},
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

local function capVector3Decimals(data, decimalCap: number)
    local function compute(uncapped)
        return math.floor(uncapped * 10^decimalCap)/10^decimalCap
    end

    local function convert(value)
		if typeof(value) == "Vector3" then
			return { compute(value.X), compute(value.Y), compute(value.Z) }
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

        local function displayResults()
            print('Sample Collected! Total logs: ' .. tostring(serverSession.frame_count))
            serverSession.joinLeaveLog = capVector3Decimals(serverSession.joinLeaveLog)
            serverSession.joinLeaveLog =  serializeVectors(serverSession.joinLeaveLog)

            serverSession.movementLog = capVector3Decimals(serverSession.movementLog)
            serverSession.movementLog = serializeVectors(serverSession.movementLog)

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

        RuntimeData.CurrentTime = os.clock()
        serverSession.log_start_time = RuntimeData.CurrentTime

        local function LogInitalPlayerPosRot()
            local logData = {time = RuntimeData.CurrentTime}

            for _, player in pairs(game.Players:GetPlayers()) do
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
            RuntimeData.CurrentTime = os.clock()
            local logData = {time = RuntimeData.CurrentTime}

            -- Logs Position and Rotation --
            for _, player in pairs(game.Players:GetPlayers()) do
                local character = player.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")
                if not hrp then continue end

                logData[player.UserId] = {
                    hrpPosition = hrp.Position,
                    hrpRotation = hrp.Orientation
                }
            end

            table.insert(serverSession.movementLog, logData)

            local shouldUpload = serverSession.frame_count+1 % Config.UploadChunkSize

            if shouldUpload then
                TempSession = serverSession
                serverSession = TempSession
                serverSession.movementLog = {}
                
                local f = {
                    logVersion = 0.01,
                    serverId = game.JobId,
                    sessionStartTimeEpoch = os.time(), -- epoch timestamp (Server Start Time)
                    sampleRate = Config.ReplaySampleRate,
                    frame_count = 0,
                    log_start_time = 0,
                    joinLeaveLog = {},    -- array of { alias = string, time = os.time(), action = "join"/"leave" }
                    alias_log = {},  -- UserId : Alias | gives each player a alias/number for sake of data storage later --
                    total_session_player_count = 0,
                    movementLog = {},
                }

                Promise.try(function()
                    Capture:_HandleChunkUpload()
                end):catch(warn)
            end

            serverSession.frame_count += 1
            task.wait(1/Config.ReplaySampleRate)
        end

        resolve()
    end)
end

--#region Connection Handlers
local function handlePlayerAdded(player)
    local userId = player.UserId
    local plrAlias = serverSession.alias_log[userId]

    if not plrAlias then -- Is new to server
        serverSession.total_session_player_count += 1
        local newAlias = tostring(serverSession.total_session_player_count)
        RuntimeData.ConnectedAliasList[userId] = newAlias -- Add to current alias log

        serverSession.alias_log[userId] = newAlias -- Add to total alias log
    else -- Isnt new to server
        RuntimeData.ConnectedAliasList[userId] = plrAlias -- Add to current alias log
    end

    table.insert(serverSession.joinLeaveLog, {
        alias = RuntimeData.ConnectedAliasList[userId],
        time = RuntimeData.CurrentTime,
        action = "join"
    })

    serverSession.joinLeaveEventCount += 1
end

local function handlePlayerRemoving(player)
    table.insert(serverSession.joinLeaveLog, {
        alias = RuntimeData.ConnectedAliasList[player.UserId],
        time = RuntimeData.CurrentTime,
        action = "leave"
    })

    RuntimeData.ConnectedAliasList[player.UserId] = nil
    serverSession.joinLeaveEventCount += 1
end


local function handleCaptureEvent(player, start)
    local enabled = RuntimeData.CaptureEnabled
    if enabled == start then warn("Same input detected! Ignoring..") return end

    if not start then
        RuntimeData.CapturePromise:cancel()
        RuntimeData.CaptureEnabled = false
        return
    end

    print("Starting new Server-Wide capture")
    RuntimeData.CaptureEnabled = true
    RuntimeData.CapturePromise = PositionCapturePromise()
end
--#endregion

--#region Module Functions

function Capture:Start()
    Connections.Join = Players.PlayerAdded:Connect(handlePlayerAdded)
    Connections.Leave = Players.PlayerRemoving:Connect(handlePlayerRemoving)
end


function Capture:Stop()
    Connections.Join:Disconnect()
    Connections.Leave:Disconnect()
end


function Capture:Init()
    CaptureRemote.OnServerEvent:Connect(handleCaptureEvent)
end

-- Other

function Capture:_HandleChunkUpload()
    local f = {
        logVersion = 0.01,
        serverId = game.JobId,
        sessionStartTimeEpoch = os.time(), -- epoch timestamp (Server Start Time)
        sampleRate = Config.ReplaySampleRate,
        frame_count = 0,
        chunk_count = 0,
        log_start_time = 0,
        joinLeaveLog = {},    -- array of { alias = string, time = os.time(), action = "join"/"leave" }
        alias_log = {},  -- UserId : Alias | gives each player a alias/number for sake of data storage later --
        total_session_player_count = 0,
        movementLog = {},
    }




    local function GetNewJoinLeaveActivity() : table
        local logDifference = {}

        for i = RuntimeData.JoinLeaveCountOnLastSave+1, #serverSession.joinLeaveLog do
            table.insert(logDifference, serverSession.joinLeaveLog[i])
        end

        return logDifference
    end

    local chunkNumber = math.floor(serverSession.frame_count / Config.UploadChunkSize)
    local chunkMetadata = {
        ChunkNumber = chunkNumber,
        JoinLeaveLogDifference = GetNewJoinLeaveActivity(),
    }


    print("Uploading the following data!!!")
    print(chunkMetadata)
end

function Capture:_GetAliasByUserId(plr, logLength: number | nil)
    logLength = logLength or #serverSession.alias_log

    for index = 1, logLength do
        local userId =  serverSession.alias_log[index].UserId

        if userId == plr.UserId then
            return serverSession.alias_log[index].Alias
        end
    end
end

--#endregion

return Capture