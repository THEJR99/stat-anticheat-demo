-- Services
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RS = game:GetService("RunService")
local TS = game:GetService("TweenService")

-- Dependencies
local Promise = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Promise"))


-- Replay system
local ReplaySystem = {}
ReplaySystem._importedData = nil
ReplaySystem._replayPromise = nil
ReplaySystem._isRunning = false

local Interface = {}
Interface.MainFrame = game.Players.LocalPlayer.PlayerGui:WaitForChild("ReplayDisplay"):WaitForChild("Content")
Interface.ReplayInput = Interface.MainFrame:WaitForChild("ReplayLabel"):WaitForChild("Entry") :: TextBox
Interface.ControlButton = Interface.MainFrame:WaitForChild("ControlLabel"):WaitForChild("Button") :: TextButton
Interface.TimeDisplay = Interface.MainFrame:WaitForChild("TimeLabel"):WaitForChild("TimeCount") :: TextLabel
Interface.FrameDisplay = Interface.MainFrame:WaitForChild("FrameLabel"):WaitForChild("FrameCount") :: TextLabel

ReplaySystem.Data = {
    PlayerLogStartTime = {}, -- { {UserId = Id, StartTime = time}, ... }  (IN DESCENDING ORDER) --
    PlayerLogStopTime = {}, -- { {UserId = Id, EndTime = time}, ... }  (IN DESCENDING ORDER) --
    ReplayDummys = {
        Reserve = {}, -- {Instance, ...} --
        InUse = {}-- {userId = Instance, ...} --
    },
    ActivePlayerReplays = {}, -- { {UserId = id, CurrentFrame = #, CurrentBufferFrame = #}, ... }  |  StartFrame --
    NameList = {}, -- { UserId = PlayerName }


    _ReplayData = {}, -- { { time = t, {userid = {pos, rot}, ...} } }
    _ReplayCacheData = { CurrentPosition = 0, FrameData = {} }, -- FrameData = { {time = t, playerLogs = { userId = {hrpPosition = Vector3(), hrpRotation = Vector3()}, ... } } }
    _ReplayCacheSize = 50, -- Caches x frames left and right.  |  50 - TimePos - 50
    ReplayClock = 0,

    ReplayPromise = nil,
}

ReplaySystem.Config = {
    SampleRate = 10,
    FrameSlipTolerance = .1, -- Out of 1 --
    PlaybackDirection = 1,
    PlaybackSpeed = 1,
}


function ReplaySystem:init()
    Interface:InitalizeElements()
end



function ReplaySystem:_InitializeReplayDummys() -- Makes all dummys needed and sends to reserve. In use are labeled by {UserId = Instance}.
    local dummyModel = game:GetService("ReplicatedStorage").Prefabs.ReplayDummy

    local joinLeaveLog = self._importedData.joinLeaveLog
    print(joinLeaveLog)

    local function getMaxLoadedPlayers()
        local currentLoaded = 0
        local maxLoaded = 0

        for i = 1, #joinLeaveLog do
            local currentData = joinLeaveLog[i]
            local action = currentData.action

            if action == "join" then
                currentLoaded += 1

                if currentLoaded > maxLoaded then
                    maxLoaded += 1
                end
                continue
            end

            currentLoaded -= 1
        end

        print("Max loaded:", maxLoaded)
        return maxLoaded
    end

    local maxLoadedPlayers = getMaxLoadedPlayers()
    print("adding dummys...")
    for _ = 1, maxLoadedPlayers do
        local toReserve = dummyModel:Clone()
        toReserve.Parent = game:GetService("ReplicatedStorage").Temp

        print("Added a dummy!")
        table.insert(self.Data.ReplayDummys.Reserve, toReserve)
    end
end


function ReplaySystem:_SetStartStopTimes()
    for userId, logs in pairs(self._importedData.movementLog) do
        self.Data.PlayerLogStartTime[userId] = logs[1].time
        self.Data.PlayerLogStopTime[userId] = logs[#logs].time
    end
end


function ReplaySystem:LoadReplayData(saveName: string)
    local saveFile = game:GetService("ReplicatedStorage").Shared.ReplayFiles:FindFirstChild(saveName)
    if not saveFile then warn("Replay file " .. saveName .. " not found!!!") return end

    saveFile = require(saveFile).data
    print("got data!")

    self._importedData = HttpService:JSONDecode(saveFile)
    print("Data decoded!")
    print(self._importedData)


    self:Reset()

    --self:_PlayReplay()

    --self:_SetStartStopTimes()
end


function ReplaySystem:_GetInitialPlayers() : table -- { UserId, ... } | Gets first player's that are should be loaded into the game when the recording started.
    local replayStart = self._importedData._logStartTime
    local joinLeaveLog = self._importedData.joinLeaveLog

    local playersToLoad = {} -- {UID = time}

    for i = 1, #joinLeaveLog do
        local logContent = joinLeaveLog[i]
        local userId = logContent.UserId
        local status = logContent.Status
        local timeStamp = logContent.timeStamp

        local function removePlayer(uid)
            for index = 1, #playersToLoad do
                if playersToLoad[i] ~= uid then continue end
                table.remove(playersToLoad, index)
            end
        end

        if status == "Joined" then
            if timeStamp > replayStart then break end -- Player is ahead of log start, stopping loading

            table.insert(playersToLoad, userId)
        end

        if status ~= "Left" then error("Malformatted entry!") return end

        removePlayer(userId)
    end

    return playersToLoad
end


function ReplaySystem:_RemoveReplayDummys()
    for _, char in pairs(self.Data.ReplayDummys.InUse) do
		char:Destroy()
	end
    self.Data.ReplayDummys.InUse = {}

    for _, char in pairs(self.Data.ReplayDummys.Reserve) do
		char:Destroy()
	end
    self.Data.ReplayDummys.Reserve = {}
end

function ReplaySystem:Reset()
	self:_RemoveReplayDummys()
    self:_InitializeReplayDummys()
end




function Interface:_updateFrameTimeUI(currentFrameNumber, currentReplayDuration)
    self.TimeDisplay.Text = tostring(currentReplayDuration)
    self.FrameDisplay.Text = tostring(currentFrameNumber)
end

function Interface:InitalizeElements()
    local enabledColor = Color3.fromRGB(165, 255, 92)
    local disabledColor = Color3.fromRGB(255, 79, 79)
    local replayRunning = false
    local loadedReplayNumber: number = 0

    self.ControlButton.MouseButton1Click:Connect(function()
        if loadedReplayNumber == 0 then return end
        replayRunning = not replayRunning

        if replayRunning then -- Start --
            self.ControlButton.BackgroundColor3 = enabledColor
            ReplaySystem:_PlayReplay()
            return
        end

        -- Stop --
        self.ControlButton.BackgroundColor3 = disabledColor
        self:_PauseReplay()
    end)

    self.ReplayInput.FocusLost:Connect(function()
        print("Checking input..")
        local input = tonumber(self.ReplayInput.Text)
        if not input or input <= 0 then
            self.ReplayInput.Text = "Invalid input!"
            return
        end

        local replayData = game:GetService("ReplicatedStorage").Shared.ReplayFiles:FindFirstChild("Replay" .. tostring(input))
        if not replayData then
            self.ReplayInput.Text = "Invalid replay file #!"
            return
        end

        ReplaySystem:LoadReplayData(replayData.Name)
        loadedReplayNumber = input
        self.FrameDisplay.Text = "0"
        self.TimeDisplay.Text = "0.00"
        self.ReplayInput.Text = "> " .. replayData.Name .. " <"
    end)
end



function ReplaySystem:_PlayReplay()
    local sampleRate = self.Config.SampleRate
    local frameSlipTolerance = self.Config.FrameSlipTolerance -- Out of 1 --
    local playbackDirection = self.Config.PlaybackDirection
    local playbackSpeed = self.Config.PlaybackSpeed
    local startTime = self._importedData._logStartTime

    --print("THIS IS START TIME", startTime)
    self.Data.ReplayClock = startTime + 0.00001 -- .00001 to allow first frame to load properly

    local internalTickRate = 20 -- Ticks per second
    local lastTick = os.clock()

    local goodAlpha = {
        {FrameA = 1, FrameB = 2, TimeSinceStart = 1, DeltaTime = .05, ReplayClock = 123.3, }
    }
    local badAlpha = {}

    goodAlpha = {}
    badAlpha = {}


    self.Data.ReplayPromise = Promise.new(function(reslove, reject, onCancel)
        local enabled = true
        local loopCount = 0

        local function cancel()
            enabled = false
        end

        onCancel(cancel)

        while enabled do
            loopCount += 1
            task.wait(1/internalTickRate)
            local newTick = os.clock()
            local deltaTime = newTick - lastTick
            lastTick = newTick

            --print("Delta time on loop " .. loopCount .. ": " .. deltaTime .. "\n\n")

            --print("ReplayClock:", self.Data.ReplayClock-startTime)

            local function setPlayerPositions(targetTime)
                local timeFromStart = (targetTime - startTime)
                local framesBetweenEstimate = math.ceil( (timeFromStart/(1/sampleRate)) )

                --print("TimeFromStart",timeFromStart)
                --print("FrameEstimate",framesBetweenEstimate)
                --print("F\n\n\n\n")

                local function findCurrentFrameAtTime(frameNumber: number) : number -- Finds current frame via frameBetweenEstimate.
                    local isFirstFrame = frameNumber == 1

                    local frameStartTime = self._importedData.movementLog[frameNumber].time
                    local frameEndTime

                    local nextFrame = self._importedData.movementLog[frameNumber+1]
                    if not nextFrame then
                        frameEndTime = frameStartTime+sampleRate
                    else
                        frameEndTime = nextFrame.time
                    end

                    local isCorrectFrame = (targetTime > frameStartTime) and (targetTime < frameEndTime)
                    local goBackFrames = targetTime < frameEndTime
                    local goForwardFrames = targetTime > frameEndTime

                    if isCorrectFrame or isFirstFrame then -- If first frame, return because there is no frames beyond that.
                        --print("Good frame!")
                        return frameNumber
                    end

                    if goBackFrames then
                        --print("GOING BACK FRAMES")
                        --print("going to frame #", frameNumber-1)
                        return findCurrentFrameAtTime(frameNumber-1)

                    elseif goForwardFrames then
                        --print("GOING FORWARD FRAMES")
                        --print("going to frame #", frameNumber+1)
                        return findCurrentFrameAtTime(frameNumber+1)
                    end

                    error("should not have reached this part of execution!")
                end

                local function getDummy(_UserId) : Model
                        --print("Getting dummy from uid:", _UserId)
                        --print(self.Data.ReplayDummys)
                        local dummyFromInUse = self.Data.ReplayDummys.InUse[_UserId]
                        if dummyFromInUse then return dummyFromInUse end

                        local replayDummy = table.remove(self.Data.ReplayDummys.Reserve, 1)
                        self.Data.ReplayDummys.InUse[_UserId] = replayDummy
                        replayDummy.Parent = game.Workspace.ReplayFolder

                        return replayDummy
                end

                local function checkForUnusedDummys(_userIdList)
                    for userId, dummy in pairs(self.Data.ReplayDummys.InUse) do
                        if _userIdList[userId] then return end

                        dummy.NameTag.TextLabel.Text = ""
                        dummy.Parent = game:GetService("ReplicatedStorage").Temp
                        table.insert(self.Data.ReplayDummys.Reserve, dummy)
                        self.Data.ReplayDummys.InUse[userId] = nil
                    end
                end



                local frameNumber = findCurrentFrameAtTime(framesBetweenEstimate)
                --print("Current Frame", frameNumber)
                --print("Time since start", math.floor(timeFromStart*10))
                local userIdList = {} -- For checking if any dummys are not in use now --

                local frameA = self._importedData.movementLog[frameNumber]
                local frameB = self._importedData.movementLog[frameNumber+1]

                local frameTimeA = frameA.time
                local frameTimeB = frameB.time

                --print("FrameTimeA", frameTimeA, "FrameTimeB", frameTimeB, "\n\n")

                local replayClockTime = self.Data.ReplayClock
                local frameDrift = (frameTimeB - frameTimeA) - (sampleRate)
                local isWithinFrameTolerance =  frameDrift <= (sampleRate * frameSlipTolerance)
                local outsideToleranceInFrame = frameDrift <= sampleRate

                local movement = deltaTime * playbackSpeed * playbackDirection
                local alpha

                if isWithinFrameTolerance then
                    --print("HEREEREREREE")
                    --print("replayClockTime",replayClockTime,"frameTimeA",frameTimeA, "movement", movement, "frameTimeB", frameTimeB, "frameTimeA", frameTimeA)
                    
                    alpha = (replayClockTime - frameTimeA + movement) / (frameTimeB - frameTimeA)
                    

                elseif outsideToleranceInFrame then
                    alpha = (replayClockTime - frameTimeA + movement) / (frameTimeB - frameTimeA)
                    --print("Frame misalignment!")
                else -- Is out of sync by a frame or more

                end

                local d = {}
                    d.Alpha = alpha
                    d.DeltaTime = deltaTime
                    d.ReplayClock = self.Data.ReplayClock
                    d.TimeSinceStart = timeFromStart
                    d.TargetFrame = frameNumber
                    d.FrameTimeA = frameTimeA
                    d.FrameTimeB = frameTimeB

                if alpha <= 1 then
                    table.insert(goodAlpha, d)
                else
                    table.insert(badAlpha, d)
                end

                --print(alpha)
                --alpha = math.clamp(alpha, 0, 1)

                for userId, data in pairs(frameA) do
                    if userId == 'time' then continue end
                    local posX, posY, posZ = table.unpack(data["hrpPosition"])
                    local rotX, rotY, rotZ = table.unpack(data["hrpRotation"])

                    --print("Y:", posY, "FrameA:", frameA)

                    local posA = Vector3.new(posX, posY, posZ)
                    local rotA = Vector3.new( math.rad(rotX), math.rad(rotY), math.rad(rotZ) )

                    local dataB = frameB[userId]
                    local posB = Vector3.new(dataB["hrpPosition"][1], dataB["hrpPosition"][2], dataB["hrpPosition"][3])
                    local rotB = Vector3.new( math.rad(dataB["hrpRotation"][1]), math.rad(dataB["hrpRotation"][2]), math.rad(dataB["hrpRotation"][3]))

                    --print(alpha)
                    local newPosition = posA:Lerp(posB, alpha)
                    local newRotation = rotA:Lerp(rotB, alpha)

                    local newCFrame = CFrame.new(newPosition) * CFrame.Angles(newRotation.X, newRotation.Y, newRotation.Z)

                    -- Check if replay dummys are in replay, if not - insert and position them --

                    userIdList[userId] = true
                    local ReplayDummy = getDummy(userId)
                    ReplayDummy:PivotTo(newCFrame)
                end

                checkForUnusedDummys(userIdList)

                Interface:_updateFrameTimeUI(frameNumber, timeFromStart)
                --print("frameA", frameTimeA, "Alpha", alpha, "frameB", frameTimeB, "frameA", frameTimeA)
                --print("framea+alpha", frameTimeA + alpha, "frameb-framea", frameTimeB - frameTimeA, "full", frameTimeA + alpha * (frameTimeB - frameTimeA))
                --print("ADVANCING TIME BY:", (frameTimeA + alpha * (frameTimeB - frameTimeA)) - self.Data.ReplayClock)
                self.Data.ReplayClock = frameTimeA + alpha * (frameTimeB - frameTimeA)
            end

            setPlayerPositions(self.Data.ReplayClock)
            --print("\n\nEND END END END END END END\n\n")
        end
    end)

    self.Data.ReplayPromise:catch(function()
        print("Good alpha:", goodAlpha)
        print("Bad alpha:", badAlpha)

        local totalAlpha = 0
        local lowestAlpha = {Alpha = 99999999999999999999}
        local highestAlpha = {Alpha = 0}

        for _, data in pairs(badAlpha) do
            local currentAlpha = data.Alpha
            
            if currentAlpha >= 10 then
                print("Really bad alpha!", currentAlpha)
                print("FrameA", data.FrameTimeA)
                print("FrameA", data.FrameTimeB,"\n\n")
                continue
            end
            
            totalAlpha += currentAlpha

            if currentAlpha < lowestAlpha.Alpha then
                lowestAlpha = data
            end

            if currentAlpha > highestAlpha.Alpha then
                highestAlpha = data
            end
        end

        print("Average Bad Alpha:", (totalAlpha/#badAlpha))
        print("Highest Bad Alpha:", highestAlpha.Alpha)
        print("Lowest Bad Alpha:", lowestAlpha.Alpha)

        print("Lowest", lowestAlpha)
        print("Highest", highestAlpha)
    end)

end




function ReplaySystem:_PauseReplay()
    RS:UnbindFromRenderStep("ReplaySystem")
end









function ReplaySystem:Start() -- Possibly Depricated :flushed:
	if not self._importedData then return end
	self._isRunning = true

    self:_InitializeReplayDummys()

    local initalCharacters = self:_GetInitialPlayers()


    local function SetNewCharacterPosition(character: Model, Position: table, Rotation: table, Time: number)
        local pos = Vector3.new(Position[1], Position[2], Position[3])
        local rot = Vector3.new(math.rad(Rotation[1]), math.rad(Rotation[2]), math.rad(Rotation[3]))

        local newCFrame = CFrame.new(pos) * CFrame.Angles(rot)

        local function TweenPivotTo(Model: Model, TargetCFrame: CFrame, _Time: number)
            return Promise.new(function(resolve, _, cancel)
                local tempCFrame = Instance.new('CFrameValue')
                tempCFrame.Value = Model:GetPivot()

                TS:Create(tempCFrame, TweenInfo.new(Time), {Value = TargetCFrame}):Play()

                local connection = tempCFrame.Changed:Connect(function(value)
                    Model:PivotTo(value)
                end)

                task.wait(Time)
                connection:Disconnect()
                tempCFrame:Destroy()
                resolve()
            end)
        end

        if not Time then
            character:PivotTo(newCFrame)
            return
        end

        TweenPivotTo(character, newCFrame, Time)
    end

    local function LoadInPlayer(UserId) -- Used when player's data and replay dummy when their data should start (Joining) --
        local data = {UserId = UserId, CurrentFrame = 1, _CurrentBufferFrame = 1}
        table.insert(self.Data.ActivePlayerReplays, data) -- Set data --

        local newDummy = self.Data.ReplayDummys.Reserve[1]

        self.Data.ReplayDummys.InUse[UserId] = newDummy
        newDummy.NameTag.TextLabel.Text = "Loading Name.."
        newDummy.Parent = workspace.ReplayFolder

        Promise.try(function() -- Tries to get name then set it to Dummy's name tag.
            local playerName = "Could Not Get Player Name."
            local retries = 0
            local maxRetries = 5

            while retries <= maxRetries do
                local success, result = pcall(function()
                    return Players:GetNameFromUserIdAsync(UserId)
                end)

                if success then
                    newDummy.NameTag.TextLabel.Text = result
                end

                print(result)
                retries += 1

                if retries <= maxRetries then
                    task.wait(1)
                end
            end
        end)

        local firstFrameReplayData = self._importedData.movementLog[UserId][1]
        local firstPos = firstFrameReplayData.hrpPosition
        local firstRot = firstFrameReplayData.hrpRotation
        SetNewCharacterPosition(newDummy, firstPos, firstRot)
    end

    local function LoadInStarterPlayerData(plrList) -- Loads starter player's logs + dummy
        for _, userId in pairs(plrList) do
            LoadInPlayer(userId)
        end
    end

    local function RemoveStartPlayersFromNextStartList() -- Removes the starter player's from the nextStartTime list to prevent two copies of the starter characters
        local totalRemoved = 0
        local toBeRemoved = initalCharacters
        for index = 1, #self.Data.PlayerLogStartTime do -- Loops through Start Times
            local currentData = self.Data.PlayerLogStartTime[index]

            for removeIndex, userId in pairs(toBeRemoved) do -- Loops through list to remove from start times
                if currentData.UserId ~= userId then continue end -- Skip if name does not match
                table.remove(self.Data.PlayerLogStartTime, index)
                table.remove(toBeRemoved, removeIndex) -- Remove from BOTH lists
                break
            end

            if #toBeRemoved == 0 then -- If all are removed, break from the function
                return
            end
        end
    end

    local function initalizeStartingPlayerPositions() -- Renders the first frame of the start players position log.
        for _, userId in pairs(initalCharacters) do
            local dummy = table.remove(self.Data.ReplayDummys.Reserve, 1)
            local pos: Vector3 = self._importedData.movementLog[userId].hrpPosition
            local rot: Vector3 = self._importedData.movementLog[userId].hrpRotation

            local newCFrame = CFrame.new(pos) * CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))

            dummy:PivotTo(newCFrame)
            dummy.Parent = workspace.ReplayFolder
        end
    end

    LoadInStarterPlayerData()
    initalizeStartingPlayerPositions() -- Render first characters
    RemoveStartPlayersFromNextStartList() -- Stop first characters rendering twice


    local function NewReplayPromise(_____self)
        return Promise.new(function(resolve, reject, onCancel)
            local enabled = true
            local sampleRate = 5
            local ReplayClockTime = self._importedData._logStartTime

            local startTimes = self.Data.PlayerLogStartTime -- uid = st --
            local nextStartTime = startTimes[1].StartTime
            local frameSlipTolerance = 10 -- In Percent --

            --self.Data.ActivePlayerReplays -- { userId = currentFrame } --

            local function CheckForNewStart() : boolean -- Returs true if the next start time (Player joining replay) is now.
                if ReplayClockTime < nextStartTime then return end

                print("Start next player!")
                return true
            end



            local function RenderNewFrames()
                local activeReplays = self.Data.ActivePlayerReplays
                local computedSampleRate = 1/sampleRate

                for index, metaData in pairs(activeReplays) do
                    local userId = metaData.UserId
                    local currentFrame = metaData.CurrentFrame
                    local frameData = self._importedData.movementLog[userId]
                    local totalFrames = #frameData

                    local isLastFrame = totalFrames == currentFrame

                    if isLastFrame then
                        print("Do something to end it")
                        -- PLAYER LEFT GAME --
                    end

                    local nextFrameData = frameData[currentFrame+1] -- {time, pos, rot} --
                    local replayMetaData = self.Data.ActivePlayerReplays -- {id, currFrame, buffFrame} --
                    local replayDummy = self.Data.ReplayDummys.InUse[userId]

                    local nextFrameTimeOffset = nextFrameData.time - ReplayClockTime -- (frameTime - clockTime) | Ideally, should be 1/sampleRate
                    local nextFrameTimeDrift = nextFrameTimeOffset - (1/sampleRate)
                    local frameDriftPercent = nextFrameTimeDrift / (1/sampleRate)

                    print("Frame time offset: " .. nextFrameTimeOffset)
                    print("Frame time drift: " .. nextFrameTimeDrift)
                    print("Frame drift percentage: " .. frameDriftPercent)

                    local isWithinTolerance = (1/frameSlipTolerance) >= frameDriftPercent
                    local isWithinFrame = nextFrameTimeDrift < (1/sampleRate)
                    local isNotWithinFrame = (not isWithinFrame and not isWithinFrame)
                    local frameAdjusted = false

                    local newPosition = nextFrameData.hrpPosition
                    local newRotation = nextFrameData.hrpRotation

                    if isWithinTolerance then -- Sets position with smooth tween
                        print("Within tolerance")
                        SetNewCharacterPosition(replayDummy, newPosition, newRotation, computedSampleRate)

                        frameAdjusted = true
                    end

                    if isWithinFrame then -- Sets position with faster tween
                        if frameAdjusted then continue end


                    end

                    if isNotWithinFrame then -- Set position immediately with no tween
                        if frameAdjusted then continue end

                        SetNewCharacterPosition(replayDummy, newPosition, newRotation)
                        frameAdjusted = true
                    end

                    self.Data.ActivePlayerReplays[index].CurrentFrame = currentFrame + 1 -- Sets frame to next frame
                end
            end


            local self_data = {
                PlayerLogStartTime = {}, -- { {UserId = Id, StartTime = time}, ... }  (IN DESCENDING ORDER) --
                ReplayDummys = {
                    Reserve = {}, -- {Instance, ...} --
                    InUse = {}-- {userId = Instance, ...} --
                },
                ActivePlayerReplays = {} -- { {UserId = id, CurrentFrame = #, CurrentBufferFrame = #}, ... }  |  StartFrame --
            }



            while enabled do
                CheckForNewStart()

                RenderNewFrames()

                task.wait(1/sampleRate)
            end


        end)
    end

	self._replayPromise = NewReplayPromise(self)
end

function ReplaySystem:SwitchReplay(newJsonString)
	self:LoadReplayData(newJsonString)
	self:Start()
end

return ReplaySystem
