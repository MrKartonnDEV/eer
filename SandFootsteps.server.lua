--[[
	Sand Footsteps (Server-Sided)

	Spawns realistic alternating footprints on any part named "Sand".
	Works on flat ground and slopes. Handles multiple players.
	Prints are offset laterally so left/right trails look natural.

	Setup in Roblox Studio:
	  ReplicatedStorage
	    └─ Footsteps (Folder)
	        ├─ FootstepSandLeft  (Part/MeshPart — Anchored, CanCollide off)
	        └─ FootstepSandRight (Part/MeshPart — Anchored, CanCollide off)

	  If only "FootstepSand" exists it will be used for both feet.
	  Place this Script in ServerScriptService.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local FootstepsFolder = ReplicatedStorage:WaitForChild("Footsteps")

----------------------------------------------------------------------
-- CONFIG — tweak these to taste
----------------------------------------------------------------------
local STEP_STRIDE           = 2    -- horizontal studs between prints
local STEP_COOLDOWN         = 0.15 -- min seconds between any two prints
local PRINT_LIFE            = 5    -- seconds a print stays fully visible
local FADE_DURATION         = 2    -- fade-out time after life expires
local SURFACE_OFFSET        = 0.06 -- tiny lift to prevent z-fighting
local RAY_DISTANCE          = 8    -- how far down to raycast from foot
local MAX_PRINTS_PER_PLAYER = 30   -- per-player cap (oldest removed first)
local LATERAL_OFFSET        = 0.5  -- studs to shift print sideways from center

-- Any part whose Name appears here counts as sand
local SAND_NAMES = {
	Sand     = true,
	SandPart = true,
}

----------------------------------------------------------------------
-- TEMPLATE LOOKUP
----------------------------------------------------------------------
local function getTemplate(side)
	return FootstepsFolder:FindFirstChild("FootstepSand" .. side)
		or FootstepsFolder:FindFirstChild("FootstepSand")
end

----------------------------------------------------------------------
-- PER-PLAYER DATA
----------------------------------------------------------------------
local playerData = {} -- [Player] -> { conn, prints }

----------------------------------------------------------------------
-- SURFACE MATH
----------------------------------------------------------------------

--- Build a CFrame lying flat on a surface, facing along a direction.
local function surfaceCFrame(pos, normal, dir)
	local projected = dir - normal * dir:Dot(normal)
	if projected.Magnitude < 0.001 then
		-- dir is nearly parallel to normal — pick an arbitrary tangent
		local ref = (math.abs(normal.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
		projected = ref - normal * ref:Dot(normal)
	end
	projected = projected.Unit
	local right = projected:Cross(normal).Unit
	return CFrame.fromMatrix(pos, right, normal, -projected)
end

--- Raycast straight down, ignoring the character.
local function castDown(origin, character)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {character}
	params.FilterType = Enum.RaycastFilterType.Exclude
	return workspace:Raycast(origin, Vector3.new(0, -RAY_DISTANCE, 0), params)
end

----------------------------------------------------------------------
-- PRINT SPAWNING
----------------------------------------------------------------------
local function spawnPrint(data, footPart, side, character, moveDir)
	local template = getTemplate(side)
	if not template then return end

	-- Raycast from the foot's bottom to place the print exactly where the sole is
	local footBottom = footPart.Position - Vector3.new(0, footPart.Size.Y * 0.5, 0)
	local hit = castDown(footBottom + Vector3.yAxis * 0.5, character)
	if not hit or not SAND_NAMES[hit.Instance.Name] then return end

	local normal   = hit.Normal
	local hitPoint = hit.Position + normal * SURFACE_OFFSET

	-- Orient flat on the surface, facing along movement
	local cf = surfaceCFrame(hitPoint, normal, moveDir)

	-- Shift left or right so the two foot trails don't overlap
	local shift = (side == "Left") and -LATERAL_OFFSET or LATERAL_OFFSET
	local finalPos = hitPoint + cf.RightVector * shift
	cf = surfaceCFrame(finalPos, normal, moveDir)

	-- Clone, position, parent
	local fp = template:Clone()
	fp.CFrame      = cf
	fp.Transparency = 0
	fp.Anchored     = true
	fp.CanCollide   = false
	fp.Parent       = workspace

	-- Track for cap enforcement
	table.insert(data.prints, fp)

	-- Remove oldest if over the limit
	while #data.prints > MAX_PRINTS_PER_PLAYER do
		local old = table.remove(data.prints, 1)
		if old and old.Parent then old:Destroy() end
	end

	-- Timed fade-out -> destroy
	task.delay(PRINT_LIFE, function()
		if not fp or not fp.Parent then return end

		local tween = TweenService:Create(fp, TweenInfo.new(FADE_DURATION), {
			Transparency = 1,
		})
		tween:Play()
		tween.Completed:Once(function()
			for i, v in ipairs(data.prints) do
				if v == fp then
					table.remove(data.prints, i)
					break
				end
			end
			if fp and fp.Parent then fp:Destroy() end
		end)
	end)
end

----------------------------------------------------------------------
-- CHARACTER LIFECYCLE
----------------------------------------------------------------------
local function onCharacterAdded(player, character)
	local humanoid = character:WaitForChild("Humanoid")
	local hrp      = character:WaitForChild("HumanoidRootPart")

	local leftFoot  = character:WaitForChild("LeftFoot", 3)
		or character:FindFirstChild("Left Leg")
	local rightFoot = character:WaitForChild("RightFoot", 3)
		or character:FindFirstChild("Right Leg")
	if not leftFoot or not rightFoot then return end

	-- Tear down previous connection if the character respawned
	if playerData[player] and playerData[player].conn then
		playerData[player].conn:Disconnect()
	end

	local data = { conn = nil, prints = {} }
	playerData[player] = data

	local lastStepPos  = hrp.Position
	local lastStepTime = tick()
	local nextLeft     = true

	data.conn = RunService.Heartbeat:Connect(function()
		if not character.Parent or not hrp.Parent then return end

		local moveDir = humanoid.MoveDirection
		if moveDir.Magnitude < 0.1 then return end
		if humanoid.FloorMaterial == Enum.Material.Air then return end

		-- Horizontal distance since last print
		local delta = hrp.Position - lastStepPos
		local hDist = Vector2.new(delta.X, delta.Z).Magnitude

		if hDist < STEP_STRIDE then return end
		if (tick() - lastStepTime) < STEP_COOLDOWN then return end

		-- Alternate feet
		local side     = nextLeft and "Left" or "Right"
		local footPart = nextLeft and leftFoot or rightFoot

		spawnPrint(data, footPart, side, character, moveDir)

		lastStepPos  = hrp.Position
		lastStepTime = tick()
		nextLeft     = not nextLeft
	end)
end

----------------------------------------------------------------------
-- PLAYER LIFECYCLE
----------------------------------------------------------------------
local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	-- If the character already exists (late join / studio quick-start)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

local function onPlayerRemoving(player)
	local data = playerData[player]
	if not data then return end

	if data.conn then data.conn:Disconnect() end

	-- Destroy all remaining prints for this player
	for _, fp in ipairs(data.prints) do
		if fp and fp.Parent then fp:Destroy() end
	end

	playerData[player] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Catch players already in the game (studio quick-start)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end
