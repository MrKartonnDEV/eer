local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local FootstepsFolder = ReplicatedStorage:WaitForChild("Footsteps")
local FootstepSandTemplate = FootstepsFolder:WaitForChild("FootstepSand")

-- CONFIG
local FOOTSTEP_LIFETIME = 3 -- how long a footstep stays fully visible
local FOOTSTEP_FADE_TIME = 1 -- fade-out duration after lifetime
local FOOTSTEP_OFFSET = 0.05 -- offset along surface normal to prevent z-fighting
local STEP_DISTANCE = 4.5 -- horizontal distance between footsteps (one per stride)
local STEP_COOLDOWN = 0.35 -- minimum time between steps per foot
local RAY_LENGTH = 6 -- raycast distance below foot (longer to catch steep slopes)
local MAX_FOOTSTEPS = 20 -- max active footsteps in workspace at once (prevents buildup)

local connections = {}
local activeFootsteps = {} -- tracks all live footstep instances

-- Get character feet
local function getFeet(character)
	return {
		Left = character:FindFirstChild("LeftFoot") or character:FindFirstChild("Left Leg"),
		Right = character:FindFirstChild("RightFoot") or character:FindFirstChild("Right Leg"),
	}
end

-- Spawn a footstep directly below a foot, aligned flush to the surface
local function spawnFootstep(footPart, character)
	if not footPart or not footPart.Parent then return end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	-- Start the ray 1 stud above the foot so we never miss the ground on slopes
	local rayOrigin = footPart.Position + Vector3.new(0, 1, 0)
	local rayDirection = Vector3.new(0, -RAY_LENGTH, 0)

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(rayOrigin, rayDirection, rayParams)
	if not result or result.Instance.Name ~= "Sand" then return end

	local normal = result.Normal
	local position = result.Position + normal * FOOTSTEP_OFFSET

	-- Use the HumanoidRootPart forward for stable orientation (foot LookVector jitters with animations)
	local charForward = hrp.CFrame.LookVector

	-- Project the forward vector onto the surface plane so the decal lies flat on slopes
	local projectedForward = charForward - normal * charForward:Dot(normal)

	-- Fallback when the character looks straight along the normal (rare edge case)
	if projectedForward.Magnitude < 0.001 then
		projectedForward = hrp.CFrame.RightVector
		projectedForward = projectedForward - normal * projectedForward:Dot(normal)
	end
	projectedForward = projectedForward.Unit

	local right = projectedForward:Cross(normal).Unit

	-- Enforce footstep cap: remove the oldest one before spawning a new one
	while #activeFootsteps >= MAX_FOOTSTEPS do
		local oldest = table.remove(activeFootsteps, 1)
		if oldest and oldest.Parent then
			oldest:Destroy()
		end
	end

	local footstep = FootstepSandTemplate:Clone()
	footstep.CFrame = CFrame.fromMatrix(position, right, normal)
	footstep.Transparency = 0
	footstep.Parent = workspace
	table.insert(activeFootsteps, footstep)

	-- Fade out then destroy
	task.delay(FOOTSTEP_LIFETIME, function()
		if footstep and footstep.Parent then
			local fadeOut = TweenService:Create(
				footstep,
				TweenInfo.new(FOOTSTEP_FADE_TIME),
				{ Transparency = 1 }
			)
			fadeOut:Play()
			fadeOut.Completed:Connect(function()
				for i, v in ipairs(activeFootsteps) do
					if v == footstep then
						table.remove(activeFootsteps, i)
						break
					end
				end
				footstep:Destroy()
			end)
		end
	end)
end

-- Setup footsteps for a character
local function setupCharacter(player, character)
	local humanoid = character:WaitForChild("Humanoid")
	local hrp = character:WaitForChild("HumanoidRootPart")
	local feet = getFeet(character)
	if not feet.Left or not feet.Right then return end

	-- Single shared tracker so left and right MUST alternate
	local lastStepPos = hrp.Position
	local lastStepTime = 0
	local nextFootLeft = true

	if connections[player] then
		connections[player]:Disconnect()
	end

	connections[player] = RunService.Heartbeat:Connect(function()
		if not character.Parent then return end
		if humanoid.MoveDirection.Magnitude <= 0 then return end
		if humanoid.FloorMaterial == Enum.Material.Air then return end

		-- Measure horizontal distance traveled since last step (either foot)
		local delta = hrp.Position - lastStepPos
		local horizDistance = Vector2.new(delta.X, delta.Z).Magnitude
		local timeSinceLast = tick() - lastStepTime

		if horizDistance >= STEP_DISTANCE and timeSinceLast >= STEP_COOLDOWN then
			local footName = nextFootLeft and "Left" or "Right"
			local footPart = feet[footName]

			spawnFootstep(footPart, character)
			lastStepPos = hrp.Position
			lastStepTime = tick()
			nextFootLeft = not nextFootLeft
		end
	end)
end

-- Player connections
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		setupCharacter(player, character)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	if connections[player] then
		connections[player]:Disconnect()
		connections[player] = nil
	end
end)
