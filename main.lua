lovr.mouse = require 'lovr-mouse'
lovr.system.openConsole()
-- ENet multiplayer implementation embedded directly
local enet = require 'enet'
local z = -2
-- Removed single light_pos - now using multiple light posts
local light_orthographic = true -- Keep for potential future use
local shadow_map_size = 4096

local debug_render_from_light = false -- Enable to render scene from light
local debug_show_shadow_map = false   -- Enable to view shadow map in overlap

-- Player model positioning
local modelHeightOffset = -0.45    -- Adjust this to move player models up (+) or down (-)
local npcModelHeightOffset = -0.45 -- Separate height offset for NPCs (they need different positioning)
local cameraHeightOffset = 0.37
local playerSpeed = 300            -- Player movement force multiplier (adjusted for 70kg mass)
local npcSpeed = 50                -- NPC movement force multiplier (increased for 70kg mass)
local npcSpeedLimit = 5            -- NPC maximum speed limit
local playerJumpForce = 200

-- Physics parameters
-- Physics collider dimensions for boxes
local boxColliderWidth = 0.4  -- Width of the box collider (X-axis)
local boxColliderHeight = 1.0 -- Height of the box collider (Y-axis)
local boxColliderDepth = 0.4  -- Depth of the box collider (Z-axis)

-- Mass configuration for players and NPCs
local playerNPCMass = 70 -- Realistic human mass (kg)

-- Inertia configuration for realistic gravity response
-- Higher inertia values make objects resist rotational changes more (more realistic for characters)
local playerNPCInertia = {
  -- Diagonal elements (Ixx, Iyy, Izz) - main rotational resistance around each axis
  playerNPCMass * 0.4, -- X-axis rotation resistance (forward/backward tumbling)
  playerNPCMass * 0.2, -- Y-axis rotation resistance (spinning around vertical axis) - lower for easier turning
  playerNPCMass * 0.4, -- Z-axis rotation resistance (side-to-side tumbling)
  -- Off-diagonal elements (Ixy, Ixz, Iyz) - coupling between rotations (usually 0 for simple shapes)
  0, 0, 0
}

-- Global spawn height configuration
-- All players and NPCs now spawn at least 1 meter above terrain using getSafeSpawnHeight()
-- This ensures no entities spawn underground or get stuck in terrain

-- Shadow mapping parameters (optimized for houses but used for all objects)
local shadow_near_plane = 0.01 -- How close shadows start to the light
local shadow_far_plane = 100   -- How far shadows extend from the light
local shadow_radius = 50       -- How wide the shadow area covers (orthographic only)
local shadow_fov = math.pi / 2 -- Field of view for perspective shadows

-- Light parameters (now used for all light posts)
local light_intensity = 1             -- Light strength multiplier
local light_color = { 1.0, 1.0, 0.8 } -- Light color (R, G, B)

-- Light posts system
local lightPosts = {}
local maxLights = 10000       -- Maximum number of lights the shader can handle
local lightPostHeight = 2     -- Height of light posts
local lightPostSpacing = 30   -- Distance between light posts
local lightRange = 30         -- Default light range
local lightBrightness = 1.2   -- Brightness multiplier for light posts
local lightsOnAllRocks = true -- If true, put lights on ALL rocks; if false, avoid rocks near houses

-- Global stats for debug display
local globalLightsRendered = 0

local shader, render_texture
local shadow_map_texture, shadow_map_sampler
local light_space_matrix
local shadow_map_pass, lighting_pass

-- ============================================================================
-- MULTIPLAYER ENET CLIENT (embedded)
-- ============================================================================
local MultiplayerENetClient = {}
MultiplayerENetClient.__index = MultiplayerENetClient

function MultiplayerENetClient.new(serverAddress, serverPort)
  local self = setmetatable({}, MultiplayerENetClient)

  self.host = nil
  self.server = nil
  self.serverAddress = serverAddress or "localhost"
  self.serverPort = serverPort or 6789
  self.connected = false
  self.playerId = nil
  self.players = {}      -- Other players' data
  self.npcsFromHost = {} -- NPCs received from host (clients only)

  -- Ping tracking
  self.ping = 0
  self.pingStartTime = 0
  self.lastPingTime = 0

  return self
end

function MultiplayerENetClient:connect()
  print("Connecting to " .. self.serverAddress .. ":" .. self.serverPort)

  -- Create client host
  self.host = enet.host_create()
  if not self.host then
    print("Failed to create ENet host")
    return false
  end

  -- Connect to server
  self.server = self.host:connect(self.serverAddress .. ":" .. self.serverPort)
  if not self.server then
    print("Failed to create connection to server")
    return false
  end

  print("ENet client created, attempting connection...")
  return true
end

function MultiplayerENetClient:disconnect()
  if self.server then
    self.server:disconnect()
    self.server = nil
  end

  if self.host then
    self.host:flush()
    -- Give time for disconnect message to send
    for i = 1, 10 do
      local event = self.host:service(100)
      if event and event.type == "disconnect" then
        break
      end
    end
    self.host = nil
  end

  -- Clean up all player colliders before clearing the players table
  if self.players then
    for playerId, playerData in pairs(self.players) do
      if playerData.collider then
        playerData.collider:destroy()
      end
    end
  end

  -- Clean up all NPC physics bodies on clients
  if self.npcsFromHost then
    for npcId, npcData in pairs(self.npcsFromHost) do
      if npcData.body then
        npcData.body:destroy()
      end
    end
  end

  -- No ghost colliders to clean up anymore

  self.connected = false
  self.players = {}
  self.npcsFromHost = {}
  self.playerId = nil
  print("Disconnected from server")
end

function MultiplayerENetClient:sendPlayerUpdate(position, yaw, isMoving)
  if not self.connected or not self.server then return end

  -- Send position updates as unreliable (fast, can be dropped)
  local movingFlag = isMoving and "1" or "0"
  local message = string.format("PLAYER_UPDATE:%.3f,%.3f,%.3f:%.3f:%s",
    position.x, position.y, position.z, yaw, movingFlag)

  -- Unreliable for position updates (speed over reliability)
  self.server:send(message, 0, "unreliable")
  -- Debug: Print occasionally to verify sending
  if math.random() < 0.1 then -- 10% chance to print
    print("DEBUG: Sending player update: " .. message)
  end
end

function MultiplayerENetClient:sendReliableMessage(message)
  if not self.connected or not self.server then return end

  -- For important messages that must arrive
  self.server:send(message, 0, "reliable")
end

function MultiplayerENetClient:sendNPCUpdate(npcData)
  if not self.connected or not self.server then return end

  -- Only the host should send NPC updates
  if multiplayerMode ~= "host" then return end

  -- Format: NPC_UPDATE:npcId:x,y,z:yaw:state:colorR,colorG,colorB:velX,velY,velZ:angVelX,angVelY,angVelZ:forceX,forceY,forceZ
  local message = string.format(
    "NPC_UPDATE:%d:%.3f,%.3f,%.3f:%.3f:%s:%.2f,%.2f,%.2f:%.3f,%.3f,%.3f:%.3f,%.3f,%.3f:%.3f,%.3f,%.3f",
    npcData.id, npcData.x, npcData.y, npcData.z, npcData.yaw, npcData.state,
    npcData.color[1], npcData.color[2], npcData.color[3],
    npcData.velX, npcData.velY, npcData.velZ,
    npcData.angVelX, npcData.angVelY, npcData.angVelZ,
    npcData.forceX, npcData.forceY, npcData.forceZ)

  -- Send as unreliable for performance (NPCs update frequently)
  self.server:send(message, 0, "unreliable")
end

function MultiplayerENetClient:sendNPCPush(npcId, newPosition, pushForce)
  if not self.connected or not self.server then
    print("DEBUG: Cannot send NPC push - not connected")
    return
  end

  -- Clients can send NPC push notifications to the host
  if multiplayerMode ~= "client" then
    print("DEBUG: Not sending NPC push - not in client mode (mode: " .. multiplayerMode .. ")")
    return
  end

  -- Format: NPC_PUSH:npcId:x,y,z:forceX,forceY,forceZ
  local message = string.format("NPC_PUSH:%d:%.3f,%.3f,%.3f:%.3f,%.3f,%.3f",
    npcId, newPosition.x, newPosition.y, newPosition.z, pushForce.x, pushForce.y, pushForce.z)

  print("DEBUG: Sending NPC push message: " .. message)

  -- Send as unreliable since pushes happen frequently
  self.server:send(message, 0, "unreliable")
end

function MultiplayerENetClient:update()
  if not self.host then return end

  -- Debug: Verify update is being called
  if math.random() < 0.001 then -- 0.1% chance
    print("DEBUG: MultiplayerENetClient:update() called, mode: " .. (multiplayerMode or "nil"))
  end

  -- Process all available events
  while true do
    local event = self.host:service(0) -- Non-blocking
    if not event then break end

    if event.type == "connect" then
      self.connected = true
      print("Connected to server!")
      -- Send join request
      self:sendReliableMessage("JOIN_GAME")
    elseif event.type == "disconnect" then
      self.connected = false
      print("Disconnected from server")
    elseif event.type == "receive" then
      self:processMessage(event.data)
    end
  end

  -- NPCs on clients are now purely visual - no physics bodies
  -- Push detection is handled in the main game loop in lovr.update()
  if self.npcsFromHost and multiplayerMode == "client" then
    -- Debug: Print NPC count occasionally
    if math.random() < 0.01 then -- 1% chance
      local npcCount = 0
      for _ in pairs(self.npcsFromHost) do npcCount = npcCount + 1 end
      print("DEBUG: Client has " .. npcCount .. " visual NPCs from host (mode: " .. multiplayerMode .. ")")
    end
  end

  -- Auto-ping server every 5 seconds to maintain fresh ping data (client side)
  if multiplayerMode == "client" and self:isConnected() then
    if not self.lastAutoPing then
      self.lastAutoPing = lovr.timer.getTime()
    end
    if lovr.timer.getTime() - self.lastAutoPing > 5.0 then
      self:pingServer()
      self.lastAutoPing = lovr.timer.getTime()
    end
  end
end

function MultiplayerENetClient:processMessage(message)
  local parts = {}
  for part in string.gmatch(message, "([^:]+)") do
    table.insert(parts, part)
  end

  if parts[1] == "PLAYER_JOIN" then
    local playerId = parts[2]
    if playerId == "YOU" then
      self.playerId = parts[3]
      print("Assigned player ID: " .. self.playerId)
    else
      -- Create physics collider for the other player at safe spawn height
      local safeSpawnHeight = getSafeSpawnHeight(0, 0)
      local playerCollider = world:newBoxCollider(0, safeSpawnHeight, 0, boxColliderWidth, boxColliderHeight,
        boxColliderDepth)
      -- Box colliders are naturally vertical (Y-axis aligned), no rotation needed
      -- Set properties for realistic player physics
      playerCollider:setLinearDamping(1.0)  -- Same damping as local player (fixed)
      playerCollider:setAngularDamping(5.0) -- Prevent spinning (fixed)
      playerCollider:setFriction(1.0)       -- High friction to reduce sliding
      playerCollider:setRestitution(0)      -- Bouncy for fun physics

      -- Set heavy mass and realistic inertia for better gravity response (same as local player)
      playerCollider:setMass(playerNPCMass)
      playerCollider:setInertia(playerNPCInertia[1], playerNPCInertia[2], playerNPCInertia[3], playerNPCInertia[4],
        playerNPCInertia[5], playerNPCInertia[6])

      -- Mark this as a visual player collider using user data
      playerCollider:setUserData({ type = "visual_player", playerId = playerId })

      print("DEBUG: Created collider for player " .. playerId .. " at position " ..
        string.format("%.2f, %.2f, %.2f", playerCollider:getPosition()))

      self.players[playerId] = {
        id = playerId,
        position = lovr.math.newVec3(0, safeSpawnHeight, 0), -- Match the collider starting position
        yaw = 0,                                             -- Store yaw directly instead of quaternion
        isMoving = false,                                    -- Track if player is moving for animation
        lastUpdate = lovr.timer.getTime(),
        collider = playerCollider                            -- Store the physics collider
      }

      -- No ghost colliders needed - clients will send push messages directly



      print("Player joined: " .. playerId .. " (Total other players: " .. self:getPlayerCount() .. ")")
    end
  elseif parts[1] == "PLAYER_LEAVE" then
    local playerId = parts[2]
    -- Remove the player's physics collider before removing the player data
    if self.players[playerId] and self.players[playerId].collider then
      self.players[playerId].collider:destroy()
    end
    -- No ghost colliders to clean up
    self.players[playerId] = nil
    print("Player left: " .. playerId .. " (Total other players: " .. self:getPlayerCount() .. ")")
  elseif parts[1] == "PLAYER_UPDATE" then
    local playerId = parts[2]
    if playerId ~= self.playerId and self.players[playerId] then
      local posData = {}
      for coord in string.gmatch(parts[3], "([^,]+)") do
        table.insert(posData, tonumber(coord))
      end

      local yaw = tonumber(parts[4])   -- Get yaw directly
      local isMoving = parts[5] == "1" -- Get movement state

      -- Update player data with interpolation support
      local player = self.players[playerId]
      player.lastPosition = lovr.math.newVec3(player.position)
      player.lastYaw = player.yaw -- Store last yaw for interpolation
      player.position:set(posData[1], posData[2], posData[3])
      player.yaw = yaw
      player.isMoving = isMoving -- Update movement state for animation
      player.lastUpdate = lovr.timer.getTime()

      -- Update the physics collider position and rotation to match the received data
      if player.collider then
        -- For non-kinematic bodies, we need to smoothly move them to the target position
        local currentX, currentY, currentZ = player.collider:getPosition()
        local targetX, targetY, targetZ = posData[1], posData[2], posData[3]

        -- Calculate the difference and apply a corrective force
        local dx = targetX - currentX
        local dy = targetY - currentY
        local dz = targetZ - currentZ
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

        -- Store physics offset for visual collision effects while maintaining network sync
        if not player.physicsOffset then
          player.physicsOffset = lovr.math.newVec3(0, 0, 0)
          player.offsetTime = lovr.timer.getTime()
        end

        -- Only capture the offset if it's significant (from actual collisions)
        if distance > 0.1 then
          player.physicsOffset:set(currentX - targetX, currentY - targetY, currentZ - targetZ)
          player.offsetTime = lovr.timer.getTime()
        end

        -- Always keep collider at network position for perfect sync
        player.collider:setPosition(targetX, targetY, targetZ)
        player.collider:setLinearVelocity(0, 0, 0)

        -- Rotate collider to match player's camera yaw
        player.collider:setOrientation(yaw, 0, 1, 0) -- angle, ax, ay, az format

        -- No ghost colliders to update
      end

      -- Debug: Print occasionally to verify receiving
      if math.random() < 0.05 then -- 5% chance to print
        print("DEBUG: Received update from player " ..
          playerId .. " at " .. posData[1] .. "," .. posData[2] .. "," .. posData[3])
      end
    elseif playerId ~= self.playerId and not self.players[playerId] then
      print("DEBUG: Received update from unknown player " .. playerId .. " - they might not have joined properly")
    end
  elseif parts[1] == "NPC_UPDATE" then
    -- Handle NPC updates from host
    local npcId = tonumber(parts[2])
    if npcId then
      -- Parse position data
      local posData = {}
      for coord in string.gmatch(parts[3], "([^,]+)") do
        table.insert(posData, tonumber(coord))
      end

      -- Parse other NPC data
      local yaw = tonumber(parts[4]) or 0
      local state = parts[5] or "wandering"

      -- Parse color data
      local colorData = {}
      for color in string.gmatch(parts[6], "([^,]+)") do
        table.insert(colorData, tonumber(color))
      end

      -- Parse velocity data
      local velData = {}
      for vel in string.gmatch(parts[7], "([^,]+)") do
        table.insert(velData, tonumber(vel))
      end

      -- Parse angular velocity data
      local angVelData = {}
      for angVel in string.gmatch(parts[8], "([^,]+)") do
        table.insert(angVelData, tonumber(angVel))
      end

      -- Parse force data
      local forceData = {}
      for force in string.gmatch(parts[9], "([^,]+)") do
        table.insert(forceData, tonumber(force))
      end

      -- Update or create NPC data (with physics bodies on clients)
      if not self.npcsFromHost[npcId] then
        -- Create physics body for NPC on client at safe spawn height
        local npcSafeHeight = getSafeSpawnHeight(posData[1] or 0, posData[3] or 0)
        local npcBody = world:newBoxCollider(posData[1] or 0, npcSafeHeight, posData[3] or 0,
          boxColliderWidth, boxColliderHeight, boxColliderDepth)
        -- Box colliders are naturally vertical (Y-axis aligned), no rotation needed
        npcBody:setLinearDamping(1.0)  -- Same damping as host (fixed)
        npcBody:setAngularDamping(5.0) -- Same damping as host (fixed)
        npcBody:setFriction(0.3)       -- Same friction as host
        npcBody:setRestitution(0)      -- Bouncy for fun physics

        -- Set heavy mass and realistic inertia for better gravity response (same as host NPCs)
        npcBody:setMass(playerNPCMass)
        npcBody:setInertia(playerNPCInertia[1], playerNPCInertia[2], playerNPCInertia[3], playerNPCInertia[4],
          playerNPCInertia[5], playerNPCInertia[6])

        -- Mark this as a client NPC collider
        npcBody:setUserData({ type = "client_npc", id = npcId })

        print("DEBUG: Client created physics NPC " ..
          npcId .. " at " .. string.format("%.1f,%.1f,%.1f", posData[1], posData[2], posData[3]))

        self.npcsFromHost[npcId] = {
          id = npcId,
          body = npcBody,
          position = lovr.math.newVec3(posData[1] or 0, npcSafeHeight, posData[3] or 0),
          yaw = yaw,
          state = state,
          color = colorData,
          lastUpdate = lovr.timer.getTime(),
          lastSyncTime = lovr.timer.getTime()
        }
      else
        -- Update existing NPC physics
        local npc = self.npcsFromHost[npcId]
        local currentTime = lovr.timer.getTime()

        -- Update position and other visual data
        npc.position:set(posData[1] or 0, posData[2] or 0, posData[3] or 0)
        npc.yaw = yaw
        npc.state = state
        npc.color = colorData
        npc.lastUpdate = currentTime

        -- Apply physics data to the body
        if npc.body and velData[1] and angVelData[1] and forceData[1] then
          -- Set velocity to match host
          npc.body:setLinearVelocity(velData[1], velData[2], velData[3])
          npc.body:setAngularVelocity(angVelData[1], angVelData[2], angVelData[3])

          -- Apply forces to match host
          npc.body:applyForce(forceData[1], forceData[2], forceData[3])

          -- Rotate NPC collider to match received yaw
          npc.body:setOrientation(yaw, 0, 1, 0) -- angle, ax, ay, az format

          -- Periodically sync position to prevent drift (every 2 seconds)
          if currentTime - npc.lastSyncTime > 2.0 then
            local currentX, currentY, currentZ = npc.body:getPosition()
            local targetX, targetY, targetZ = posData[1], posData[2], posData[3]
            local distance = math.sqrt((currentX - targetX) ^ 2 + (currentY - targetY) ^ 2 + (currentZ - targetZ) ^ 2)

            -- If position has drifted too much, snap back to host position
            if distance > 1.0 then
              -- Validate Y position - don't teleport NPCs underground
              local validatedY = targetY
              if targetY < -0.1 then     -- Ground is at 0, so -0.1 prevents going underground
                validatedY = currentY    -- Keep current Y position if target is too low
                print("DEBUG: Rejected invalid Y position " .. string.format("%.2f", targetY) .. " for NPC " .. npcId)
              elseif targetY > 20.0 then -- Don't allow NPCs to be teleported too high in the air
                validatedY = currentY    -- Keep current Y position if target is too high
                print("DEBUG: Rejected invalid Y position " .. string.format("%.2f", targetY) .. " for NPC " .. npcId)
              end

              npc.body:setPosition(targetX, validatedY, targetZ)
              print("DEBUG: Synced NPC " ..
                npcId .. " position due to drift (" .. string.format("%.2f", distance) .. " units)" ..
                " Y: " .. string.format("%.2f", targetY) .. " -> " .. string.format("%.2f", validatedY))
            end

            npc.lastSyncTime = currentTime
          end
        end
      end
    end
  elseif parts[1] == "POSITION_CORRECTION" then
    -- Host has pushed our character, apply the correction
    local posData = {}
    for coord in string.gmatch(parts[2], "([^,]+)") do
      table.insert(posData, tonumber(coord))
    end

    if posData[1] and posData[2] and posData[3] then
      -- Apply the position correction to our player with some force for natural feel
      local currentX, currentY, currentZ = player:getPosition()
      local forceX = (posData[1] - currentX) * 1000
      local forceY = (posData[2] - currentY) * 1000
      local forceZ = (posData[3] - currentZ) * 1000

      player:applyForce(forceX, forceY, forceZ)
      print("DEBUG: Received position correction from host: " ..
        string.format("%.2f,%.2f,%.2f", posData[1], posData[2], posData[3]))
    end
  elseif parts[1] == "PING" then
    -- Respond to server ping
    self:sendReliableMessage("PONG")
  elseif parts[1] == "PONG" then
    -- Server responded to our ping, calculate ping time
    if self.pingStartTime > 0 then
      local currentTime = lovr.timer.getTime()
      self.ping = (currentTime - self.pingStartTime) * 1000 -- Convert to milliseconds
      self.lastPingTime = currentTime
      self.pingStartTime = 0                                -- Reset for next ping
    end
  end
end

function MultiplayerENetClient:drawOtherPlayers(pass)
  if not self.players or not playerModel then
    return
  end

  local currentTime = lovr.timer.getTime()
  local playerCount = 0
  for _ in pairs(self.players) do playerCount = playerCount + 1 end

  -- Debug: Print occasionally to verify this function is being called
  if math.random() < 0.01 then -- 1% chance to print
    print("DEBUG: drawOtherPlayers called with " .. playerCount .. " players")
  end

  for playerId, playerData in pairs(self.players) do
    -- Use network position with physics offset for collision visual effects
    local renderPos = lovr.math.newVec3(playerData.position)

    -- Apply interpolation for network position
    if playerData.lastPosition then
      local timeSinceUpdate = currentTime - playerData.lastUpdate
      local alpha = math.min(timeSinceUpdate * 20, 1.0)

      if alpha < 1.0 then
        -- Interpolate for smoother movement
        renderPos:set(playerData.lastPosition):lerp(playerData.position, alpha)
      end
    end

    -- Apply physics offset with time-based decay for collision effects
    if playerData.physicsOffset and playerData.offsetTime then
      local timeSinceOffset = currentTime - playerData.offsetTime
      local decayDuration = 0.5 -- How long the offset lasts (0.5 seconds)

      if timeSinceOffset < decayDuration then
        -- Apply decaying offset for visual collision feedback
        local decayFactor = 1.0 - (timeSinceOffset / decayDuration)
        local scaledOffset = lovr.math.newVec3(playerData.physicsOffset):mul(decayFactor)
        renderPos:add(scaledOffset)
      end
    end

    -- Always draw the player model
    pass:push()
    pass:translate(renderPos.x, renderPos.y + modelHeightOffset, renderPos.z)
    pass:rotate(playerData.yaw + math.pi, 0, 1, 0) -- Rotate with yaw + 180 degrees to face forward
    pass:scale(0.49, 0.49, 0.49)

    -- Debug: Print occasionally to verify this model is being drawn
    if math.random() < 0.02 then -- 2% chance to print
      print("DEBUG: Drawing player " .. playerId .. " at position (" ..
        string.format("%.2f", renderPos.x) .. ", " ..
        string.format("%.2f", renderPos.y + modelHeightOffset) .. ", " ..
        string.format("%.2f", renderPos.z) .. ")")
    end

    -- Animate the model if player is moving
    if playerData.isMoving then
      playerModel:animate(1, lovr.timer.getTime())
    end

    -- Set color to white for natural model colors
    pass:setColor(1, 1, 1)
    pass:draw(playerModel)
    pass:pop()

    -- Debug: Draw collider outline if the collider exists and debug is enabled
    if _G.showColliderDebug and playerData.collider then
      local colliderX, colliderY, colliderZ = playerData.collider:getPosition()
      local qx, qy, qz, qw = playerData.collider:getOrientation()
      pass:setColor(1, 0, 0, 0.3) -- Semi-transparent red for player colliders
      -- Use Pass:box to draw the exact same shape as the physics collider
      -- Apply the same rotation as the physics collider
      pass:push()
      pass:translate(colliderX, colliderY, colliderZ)
      pass:rotate(qw, qx, qy, qz)                                              -- Apply collider's rotation
      pass:box(0, 0, 0, boxColliderWidth, boxColliderHeight, boxColliderDepth) -- Use actual box shape dimensions
      pass:pop()
      pass:setColor(1, 1, 1)                                                   -- Reset color
    end

    -- No ghost colliders to draw
  end
end

function MultiplayerENetClient:getPlayerCount()
  local count = 0
  for _ in pairs(self.players) do
    count = count + 1
  end
  return count
end

function MultiplayerENetClient:isConnected()
  return self.connected and self.server ~= nil
end

function MultiplayerENetClient:pingServer()
  if not self.connected or not self.server then return end

  self.pingStartTime = lovr.timer.getTime()
  self:sendReliableMessage("PING")
end

-- ============================================================================
-- MULTIPLAYER ENET SERVER (embedded)
-- ============================================================================
local MultiplayerENetServer = {}
MultiplayerENetServer.__index = MultiplayerENetServer

function MultiplayerENetServer.new(port)
  local self = setmetatable({}, MultiplayerENetServer)

  self.port = port or 6789
  self.host = nil
  self.clients = {}
  self.peerToPlayerId = {} -- Mapping from peer objects to player IDs
  self.running = false
  self.nextPlayerId = 1

  -- Ping tracking for server
  self.clientPings = {} -- Maps playerIds to ping values

  return self
end

function MultiplayerENetServer:start()
  print("Starting ENet server on port " .. self.port)

  -- Create server host
  self.host = enet.host_create("*:" .. self.port)
  if not self.host then
    print("Failed to create ENet host")
    return false
  end

  self.running = true
  print("ENet server started successfully!")
  print("Waiting for connections on port " .. self.port)

  return true
end

function MultiplayerENetServer:stop()
  print("Stopping ENet server...")

  if self.host then
    -- Disconnect all clients gracefully
    for playerId, client in pairs(self.clients) do
      if client.peer then
        client.peer:disconnect()
      end
    end

    -- Flush and wait for disconnections
    self.host:flush()
    for i = 1, 100 do -- Wait up to 1 second
      local event = self.host:service(10)
      if event and event.type == "disconnect" then
        print("Client disconnected during shutdown")
      end
    end

    self.host = nil
  end

  self.clients = {}
  self.running = false
  print("ENet server stopped")
end

function MultiplayerENetServer:update()
  if not self.running or not self.host then return end

  -- Process all available events
  while true do
    local event = self.host:service(0) -- Non-blocking
    if not event then break end

    if event.type == "connect" then
      self:handleClientConnect(event.peer)
    elseif event.type == "disconnect" then
      self:handleClientDisconnect(event.peer)
    elseif event.type == "receive" then
      self:handleClientMessage(event.peer, event.data)
    end
  end

  -- Auto-ping clients every 5 seconds to maintain fresh ping data
  if not self.lastAutoPing then
    self.lastAutoPing = lovr.timer.getTime()
  end
  if lovr.timer.getTime() - self.lastAutoPing > 5.0 then
    self:pingClients()
    self.lastAutoPing = lovr.timer.getTime()
  end
end

function MultiplayerENetServer:handleClientConnect(peer)
  local playerId = tostring(self.nextPlayerId)
  self.nextPlayerId = self.nextPlayerId + 1

  local client = {
    peer = peer,
    id = playerId,
    position = { x = 0, y = 5.5, z = 0 },
    yaw = 0,
    lastSeen = lovr.timer.getTime(),
    pingStartTime = 0
  }

  -- Store mapping from peer to playerId (connect_id() is read-only)
  self.peerToPlayerId = self.peerToPlayerId or {}
  self.peerToPlayerId[peer] = playerId
  self.clients[playerId] = client

  -- Initialize ping tracking for this client
  self.clientPings[playerId] = 0

  print("[" .. os.date("%H:%M:%S") .. "] Player " .. playerId .. " connected (" .. self:getClientCount() .. " total)")
end

function MultiplayerENetServer:handleClientDisconnect(peer)
  self.peerToPlayerId = self.peerToPlayerId or {}
  local playerId = self.peerToPlayerId[peer]
  if playerId and self.clients[playerId] then
    self.clients[playerId] = nil
    self.peerToPlayerId[peer] = nil -- Clean up mapping

    -- Clean up ping tracking
    self.clientPings[playerId] = nil

    -- Notify other clients
    self:broadcast("PLAYER_LEAVE:" .. playerId, playerId)

    print("[" ..
      os.date("%H:%M:%S") .. "] Player " .. playerId .. " disconnected (" .. self:getClientCount() .. " total)")
  end
end

function MultiplayerENetServer:handleClientMessage(peer, message)
  self.peerToPlayerId = self.peerToPlayerId or {}
  local playerId = self.peerToPlayerId[peer]
  local client = self.clients[playerId]

  if not client then
    print("Received message from unknown client")
    return
  end

  client.lastSeen = lovr.timer.getTime()

  local parts = {}
  for part in string.gmatch(message, "([^:]+)") do
    table.insert(parts, part)
  end

  if parts[1] == "JOIN_GAME" then
    -- Send player ID to new client
    self:sendToClient(client, "PLAYER_JOIN:YOU:" .. playerId, "reliable")

    -- Notify other clients about new player
    local sentCount = self:broadcast("PLAYER_JOIN:" .. playerId, playerId, "reliable")
    print("DEBUG: Notified " .. sentCount .. " other clients about new player " .. playerId)

    -- Send existing players to new client
    for existingId, existingClient in pairs(self.clients) do
      if existingId ~= playerId then
        self:sendToClient(client, "PLAYER_JOIN:" .. existingId, "reliable")
        print("DEBUG: Told new player " .. playerId .. " about existing player " .. existingId)
      end
    end
  elseif parts[1] == "PLAYER_UPDATE" then
    -- Parse position
    local posData = {}
    for coord in string.gmatch(parts[2], "([^,]+)") do
      table.insert(posData, tonumber(coord))
    end

    -- Parse yaw and movement state
    local yaw = tonumber(parts[3])
    local isMoving = parts[4] or "0" -- Default to not moving if not provided

    -- Update client data
    client.position = { x = posData[1], y = posData[2], z = posData[3] }
    client.yaw = yaw
    client.isMoving = isMoving == "1"

    -- Broadcast to other clients (unreliable for speed)
    local broadcastMessage = "PLAYER_UPDATE:" .. client.id .. ":" .. parts[2] .. ":" .. parts[3] .. ":" .. isMoving
    local sentCount = self:broadcast(broadcastMessage, client.id, "unreliable")

    -- Debug: Print occasionally to verify broadcasting
    if math.random() < 0.02 then -- 2% chance to print
      print("DEBUG: Player " .. client.id .. " moved, broadcasted to " .. sentCount .. " other clients")
    end
  elseif parts[1] == "NPC_UPDATE" then
    -- Relay NPC updates from host to all other clients
    local npcMessage = message -- Forward the entire message as-is
    local sentCount = self:broadcast(npcMessage, client.id, "unreliable")

    -- Debug: Print occasionally to verify NPC broadcasting
    if math.random() < 0.05 then -- 5% chance to print
      print("DEBUG: Relayed NPC update from host to " .. sentCount .. " clients")
    end
  elseif parts[1] == "NPC_PUSH" then
    -- Handle NPC push from client (forward to host's NPC system)
    local npcId = tonumber(parts[2])
    print("DEBUG: Server received NPC_PUSH message for NPC " .. (npcId or "nil"))
    if npcId and npcs then
      -- Find the NPC by its ID (since npcs is an array, not a hash table)
      local targetNPC = nil
      for i, npc in ipairs(npcs) do
        if npc.id == npcId then
          targetNPC = npc
          break
        end
      end

      if targetNPC then
        -- Parse position and force data
        local posData = {}
        for coord in string.gmatch(parts[3], "([^,]+)") do
          table.insert(posData, tonumber(coord))
        end

        local forceData = {}
        for force in string.gmatch(parts[4], "([^,]+)") do
          table.insert(forceData, tonumber(force))
        end

        -- Apply the push to the host's NPC
        if targetNPC.body and posData[1] and forceData[1] then
          -- Get current position for validation
          local currentX, currentY, currentZ = targetNPC.body:getPosition()
          local targetX, targetY, targetZ = posData[1], posData[2], posData[3]

          -- Validate Y position for push events - don't let clients push NPCs underground or too high
          local validatedY = targetY
          if targetY < -0.1 then     -- Ground is at 0, so -0.1 prevents going underground
            validatedY = currentY    -- Keep current Y position if target is too low
            print("DEBUG: Push rejected invalid Y position " .. string.format("%.2f", targetY) .. " for NPC " .. npcId)
          elseif targetY > 20.0 then -- Don't allow NPCs to be pushed too high in the air
            validatedY = currentY    -- Keep current Y position if target is too high
            print("DEBUG: Push rejected invalid Y position " .. string.format("%.2f", targetY) .. " for NPC " .. npcId)
          end

          -- Set the NPC to the validated pushed position
          targetNPC.body:setPosition(targetX, validatedY, targetZ)

          -- Apply some of the push force to continue the movement
          targetNPC.body:applyForce(forceData[1] * 0.3, forceData[2] * 0.3, forceData[3] * 0.3)

          -- Temporarily disable AI movement to let the push take effect
          targetNPC.stuckTimer = 0                                      -- Reset stuck timer
          targetNPC.wanderChangeTimer = targetNPC.wanderChangeTimer - 5 -- Delay next wander change

          print("DEBUG: Applied push from client to NPC " .. npcId .. " at position " ..
            string.format("%.2f,%.2f,%.2f", targetX, validatedY, targetZ) ..
            " (Y: " .. string.format("%.2f", targetY) .. " -> " .. string.format("%.2f", validatedY) .. ")")
        end
      else
        print("DEBUG: Could not find NPC with ID " .. npcId .. " on host")
      end
    end
  elseif parts[1] == "PONG" then
    -- Client responded to ping, calculate ping time
    client.lastSeen = lovr.timer.getTime()
    if client.pingStartTime > 0 then
      local pingTime = (client.lastSeen - client.pingStartTime) * 1000 -- Convert to milliseconds
      self.clientPings[client.id] = pingTime
      client.pingStartTime = 0                                         -- Reset for next ping
    end
  elseif parts[1] == "PING" then
    -- Client is pinging us, respond with PONG
    self:sendToClient(client, "PONG", "reliable")
  else
    print("[" .. os.date("%H:%M:%S") .. "] Unknown message from " .. client.id .. ": " .. message)
  end
end

function MultiplayerENetServer:sendToClient(client, message, reliability)
  if not client.peer then return false end

  reliability = reliability or "reliable"
  client.peer:send(message, 0, reliability)
  return true
end

function MultiplayerENetServer:broadcast(message, excludePlayerId, reliability)
  reliability = reliability or "reliable"
  local sentCount = 0

  for playerId, client in pairs(self.clients) do
    if playerId ~= excludePlayerId then
      if self:sendToClient(client, message, reliability) then
        sentCount = sentCount + 1
      end
    end
  end

  return sentCount
end

function MultiplayerENetServer:getClientCount()
  local count = 0
  for _ in pairs(self.clients) do
    count = count + 1
  end
  return count
end

function MultiplayerENetServer:pingClients()
  -- Send ping to all clients to check connectivity and measure latency
  local currentTime = lovr.timer.getTime()
  for playerId, client in pairs(self.clients) do
    client.pingStartTime = currentTime
  end
  self:broadcast("PING", nil, "reliable")
end

-- ============================================================================
-- INFINITE TERRAIN TILE SYSTEM
-- ============================================================================

-- Terrain tile configuration
local tileSize = 30               -- Size of each terrain tile (256x256 units)
local tileSubdivisions = 30       -- Subdivisions per tile (good balance of detail and performance)
local terrainRenderDistance = 500 -- How far to render terrain tiles (should be <= renderDistance)
local terrainLoadDistance = 500   -- How far to load terrain tiles (increased buffer to prevent gaps)

-- Terrain tile management
local terrainTiles = {}     -- Hash table: "x,z" -> tile data
local activeTiles = {}      -- Array of currently active tiles for easy iteration
local lastPlayerTileX = nil -- Last player tile position (for change detection)
local lastPlayerTileZ = nil

-- Function to get tile coordinates from world position
local function worldToTileCoords(worldX, worldZ)
  return math.floor(worldX / tileSize), math.floor(worldZ / tileSize)
end

-- Function to get tile key string
local function getTileKey(tileX, tileZ)
  return tileX .. "," .. tileZ
end

-- Function to get world position from tile coordinates
local function tileToWorldCoords(tileX, tileZ)
  return tileX * tileSize, tileZ * tileSize
end

-- Generate a single terrain tile mesh
local function generateTerrainTile(tileX, tileZ)
  local vertices = {}
  local indices = {}

  -- Calculate world offset for this tile
  local worldOffsetX, worldOffsetZ = tileToWorldCoords(tileX, tileZ)

  -- Generate vertices for this tile
  local step = tileSize / (tileSubdivisions - 1)

  for z = 0, tileSubdivisions - 1 do
    for x = 0, tileSubdivisions - 1 do
      -- Calculate world coordinates
      local worldX = worldOffsetX + (x * step)
      local worldZ = worldOffsetZ + (z * step)
      local worldY = terrainHeightFunction(worldX, worldZ)

      -- Calculate normal by sampling nearby points
      local normalX, normalY, normalZ = 0, 1, 0 -- Default upward normal

      if x > 0 and x < tileSubdivisions - 1 and z > 0 and z < tileSubdivisions - 1 then
        local h_left = terrainHeightFunction(worldX - step, worldZ)
        local h_right = terrainHeightFunction(worldX + step, worldZ)
        local h_down = terrainHeightFunction(worldX, worldZ - step)
        local h_up = terrainHeightFunction(worldX, worldZ + step)

        -- Calculate gradients
        local dx = (h_right - h_left) / (2 * step)
        local dz = (h_up - h_down) / (2 * step)

        -- Calculate normal from gradients
        normalX = -dx
        normalY = 1.0
        normalZ = -dz

        -- Normalize the normal vector
        local length = math.sqrt(normalX * normalX + normalY * normalY + normalZ * normalZ)
        if length > 0 then
          normalX = normalX / length
          normalY = normalY / length
          normalZ = normalZ / length
        end
      end

      table.insert(vertices, {
        worldX, worldY, worldZ,     -- position
        normalX, normalY, normalZ,  -- normal
        x / (tileSubdivisions - 1), -- u coordinate
        z / (tileSubdivisions - 1)  -- v coordinate
      })
    end
  end

  -- Generate indices for triangles
  for z = 0, tileSubdivisions - 2 do
    for x = 0, tileSubdivisions - 2 do
      local topLeft = z * tileSubdivisions + x + 1
      local topRight = z * tileSubdivisions + (x + 1) + 1
      local bottomLeft = (z + 1) * tileSubdivisions + x + 1
      local bottomRight = (z + 1) * tileSubdivisions + (x + 1) + 1

      -- First triangle
      table.insert(indices, topLeft)
      table.insert(indices, topRight)
      table.insert(indices, bottomLeft)

      -- Second triangle
      table.insert(indices, topRight)
      table.insert(indices, bottomRight)
      table.insert(indices, bottomLeft)
    end
  end

  return vertices, indices
end

-- Create a terrain tile with both physics and graphics
local function createTerrainTile(tileX, tileZ)
  local tileKey = getTileKey(tileX, tileZ)

  -- Don't create if already exists
  if terrainTiles[tileKey] then
    return terrainTiles[tileKey]
  end

  -- Generate tile mesh
  local vertices, indices = generateTerrainTile(tileX, tileZ)
  local mesh = lovr.graphics.newMesh(vertices)
  mesh:setIndices(indices)

  -- Create terrain physics collider for this tile
  local worldOffsetX, worldOffsetZ = tileToWorldCoords(tileX, tileZ)

  -- Create a height function for this specific tile
  -- LOVR TerrainCollider passes coordinates from -tileSize/2 to +tileSize/2
  local function tileHeightFunction(x, z)
    -- Convert from TerrainCollider's coordinate system to world coordinates
    -- TerrainCollider uses -tileSize/2 to +tileSize/2, we need to offset to world coords
    local worldX = worldOffsetX + tileSize / 2 + x
    local worldZ = worldOffsetZ + tileSize / 2 + z
    return terrainHeightFunction(worldX, worldZ)
  end

  local collider = world:newTerrainCollider(tileSize, tileHeightFunction, tileSubdivisions)
  if collider then
    -- CRITICAL: Set terrain collider as kinematic (static) so it doesn't fall
    collider:setKinematic(true)

    -- Position the collider at the tile's world position
    -- Since TerrainCollider uses -tileSize/2 to +tileSize/2 internally, center it properly
    collider:setPosition(worldOffsetX + tileSize / 2, 0, worldOffsetZ + tileSize / 2)
    collider:setUserData({ type = "terrain", tileX = tileX, tileZ = tileZ })

    print("DEBUG: Created kinematic terrain collider for tile (" .. tileX .. ", " .. tileZ .. ") at position (" ..
      (worldOffsetX + tileSize / 2) .. ", 0, " .. (worldOffsetZ + tileSize / 2) .. ")")
  else
    print("ERROR: Failed to create terrain collider for tile (" .. tileX .. ", " .. tileZ .. ")")
  end

  -- Create tile data structure
  local tile = {
    tileX = tileX,
    tileZ = tileZ,
    worldX = worldOffsetX,
    worldZ = worldOffsetZ,
    mesh = mesh,
    collider = collider,
    vertices = vertices,
    indices = indices
  }

  terrainTiles[tileKey] = tile
  table.insert(activeTiles, tile)

  print("Created terrain tile (" .. tileX .. ", " .. tileZ .. ") at world (" ..
    worldOffsetX .. ", " .. worldOffsetZ .. ")")

  return tile
end

-- Debug function to test terrain physics vs graphics alignment
function debugTerrainPhysicsAlignment(testX, testZ)
  print("=== TERRAIN PHYSICS vs GRAPHICS ALIGNMENT TEST ===")
  print("Test position: (" .. string.format("%.2f", testX) .. ", " .. string.format("%.2f", testZ) .. ")")

  -- Get graphics height from height function
  local graphicsHeight = terrainHeightFunction(testX, testZ)
  print("Graphics height: " .. string.format("%.3f", graphicsHeight))

  -- Get physics height by raycasting
  local physicsHeight = nil
  local rayStartY = graphicsHeight + 50 -- Start well above expected terrain
  local rayEndY = graphicsHeight - 10   -- End well below expected terrain

  world:raycast(testX, rayStartY, testZ, testX, rayEndY, testZ, nil, function(shape, x, y, z, nx, ny, nz)
    if shape and shape.getCollider then
      local collider = shape:getCollider()
      local userData = collider:getUserData()
      if userData and userData.type == "terrain" then
        physicsHeight = y
        print("Physics height: " ..
          string.format("%.3f", physicsHeight) .. " (tile " .. userData.tileX .. "," .. userData.tileZ .. ")")
        return false -- Stop at first terrain hit
      end
    end
  end)

  if physicsHeight then
    local difference = math.abs(physicsHeight - graphicsHeight)
    print("Difference: " .. string.format("%.3f", difference) .. " units")

    if difference < 0.1 then
      print("✓ GOOD: Physics and graphics are aligned!")
    else
      print("✗ BAD: Significant misalignment detected!")
    end
  else
    print("✗ ERROR: No physics terrain found at this location!")
  end

  print("=" .. string.rep("=", 50))
  return physicsHeight
end

-- Debug function to check what's under the player's feet
function debugPlayerFooting()
  if not player then
    print("No player found!")
    return
  end

  local px, py, pz = player:getPosition()
  print("=== PLAYER FOOTING DEBUG ===")
  print("Player position: (" ..
    string.format("%.2f", px) .. ", " .. string.format("%.2f", py) .. ", " .. string.format("%.2f", pz) .. ")")

  -- Check which tile the player should be on
  local playerTileX, playerTileZ = worldToTileCoords(px, pz)
  local tileKey = getTileKey(playerTileX, playerTileZ)
  local tile = terrainTiles[tileKey]

  print("Player should be on tile: (" .. playerTileX .. ", " .. playerTileZ .. ")")
  print("Tile exists: " .. tostring(tile ~= nil))

  if tile then
    print("Tile collider exists: " .. tostring(tile.collider ~= nil))
    if tile.collider then
      print("Tile collider kinematic: " .. tostring(tile.collider:isKinematic()))
      local tx, ty, tz = tile.collider:getPosition()
      print("Tile collider position: (" ..
        string.format("%.2f", tx) .. ", " .. string.format("%.2f", ty) .. ", " .. string.format("%.2f", tz) .. ")")
    end
  else
    print("WARNING: Player is not on a loaded terrain tile!")
  end

  -- Raycast down from player to see what we hit
  print("Raycasting down from player...")
  local hitSomething = false
  local rayStartY = py + 0.5 -- Start slightly above player
  local rayEndY = py - 10    -- End well below player

  world:raycast(px, rayStartY, pz, px, rayEndY, pz, nil, function(shape, x, y, z, nx, ny, nz)
    if shape and shape.getCollider then
      local collider = shape:getCollider()
      local userData = collider:getUserData()
      local colliderType = userData and userData.type or "unknown"
      print("Hit: " ..
        colliderType .. " at Y=" .. string.format("%.3f", y) .. " (distance: " .. string.format("%.3f", py - y) .. ")")
      hitSomething = true
      if userData and userData.type == "terrain" then
        return false -- Stop at first terrain hit
      end
    end
  end)

  if not hitSomething then
    print("ERROR: No collision found below player - FALLING THROUGH!")
  end

  -- Check player velocity to see if falling
  local vx, vy, vz = player:getLinearVelocity()
  print("Player velocity: (" ..
    string.format("%.2f", vx) .. ", " .. string.format("%.2f", vy) .. ", " .. string.format("%.2f", vz) .. ")")
  if vy < -1 then
    print("WARNING: Player is falling rapidly!")
  end

  print("=" .. string.rep("=", 30))
end

-- Remove a terrain tile
local function removeTerrainTile(tileX, tileZ)
  local tileKey = getTileKey(tileX, tileZ)
  local tile = terrainTiles[tileKey]

  if not tile then return end

  -- Destroy physics collider
  if tile.collider then
    tile.collider:destroy()
  end

  -- Remove from active tiles array
  for i = #activeTiles, 1, -1 do
    if activeTiles[i] == tile then
      table.remove(activeTiles, i)
      break
    end
  end

  -- Remove from tiles hash table
  terrainTiles[tileKey] = nil

  print("Removed terrain tile (" .. tileX .. ", " .. tileZ .. ")")
end

-- Update terrain tiles based on player position
local function updateTerrainTiles()
  if not player then return end

  local playerX, playerY, playerZ = player:getPosition()
  local playerTileX, playerTileZ = worldToTileCoords(playerX, playerZ)

  -- Only update if player moved to a different tile
  if playerTileX == lastPlayerTileX and playerTileZ == lastPlayerTileZ then
    return
  end

  lastPlayerTileX = playerTileX
  lastPlayerTileZ = playerTileZ

  -- Calculate how many tiles to load around player (ensure minimum 3x3 grid)
  local loadRadius = math.max(2, math.ceil(terrainLoadDistance / tileSize))

  -- Mark tiles that should exist
  local shouldExist = {}
  for x = playerTileX - loadRadius, playerTileX + loadRadius do
    for z = playerTileZ - loadRadius, playerTileZ + loadRadius do
      local distance = math.sqrt((x - playerTileX) ^ 2 + (z - playerTileZ) ^ 2) * tileSize
      if distance <= terrainLoadDistance then
        shouldExist[getTileKey(x, z)] = { x = x, z = z }
      end
    end
  end

  -- Always ensure immediate 3x3 grid around player exists (prevent gaps)
  for x = playerTileX - 1, playerTileX + 1 do
    for z = playerTileZ - 1, playerTileZ + 1 do
      shouldExist[getTileKey(x, z)] = { x = x, z = z }
    end
  end

  -- Remove tiles that are too far away
  local toRemove = {}
  for tileKey, tile in pairs(terrainTiles) do
    if not shouldExist[tileKey] then
      table.insert(toRemove, { tile.tileX, tile.tileZ })
    end
  end

  for _, coords in ipairs(toRemove) do
    removeTerrainTile(coords[1], coords[2])
  end

  -- Create tiles that don't exist but should
  for tileKey, coords in pairs(shouldExist) do
    if not terrainTiles[tileKey] then
      createTerrainTile(coords.x, coords.z)
    end
  end

  print("Terrain tiles update: Player at tile (" .. playerTileX .. ", " .. playerTileZ ..
    "), Active tiles: " .. #activeTiles)
end

-- Render all active terrain tiles
local function renderTerrainTiles(pass)
  if not player then return end

  local playerX, playerY, playerZ = player:getPosition()
  local tilesRendered = 0

  pass:setColor(0.3, 0.7, 0.2) -- Green terrain color

  for _, tile in ipairs(activeTiles) do
    -- Calculate distance from player to tile center
    local tileCenterX = tile.worldX + tileSize / 2
    local tileCenterZ = tile.worldZ + tileSize / 2
    local distance = math.sqrt((tileCenterX - playerX) ^ 2 + (tileCenterZ - playerZ) ^ 2)

    -- Only render if within render distance
    if distance <= terrainRenderDistance then
      pass:draw(tile.mesh)
      tilesRendered = tilesRendered + 1
    end
  end

  -- Debug: Print tile count occasionally
  if math.random() < 0.01 then -- 1% chance per frame
    print("Terrain tiles rendered: " .. tilesRendered .. "/" .. #activeTiles)
  end
end

-- Simple test terrain height function - for debugging alignment issues
function simpleTerrainHeightFunction(x, z)
  -- Extremely simple function for testing - just a flat plane with slight slope
  return 10 + x * 0.01 + z * 0.01 -- Flat at height 10 with very gentle slope
end

-- Terrain height function - defines the shape of the terrain
-- This function receives coordinates in the range -terrainSize/2 to terrainSize/2
function terrainHeightFunction(x, z)
  -- Add debug logging for the first few calls to understand what LOVR is doing
  if not _G.terrainHeightCallCount then _G.terrainHeightCallCount = 0 end
  _G.terrainHeightCallCount = _G.terrainHeightCallCount + 1

  -- Create gentle terrain using multiple layers of noise with much reduced amplitudes
  local height = 0

  -- Base terrain with gentle rolling hills (reduced from 40 to 8)
  height = height + 8 * (lovr.math.noise(x * 0.005, z * 0.005) - 0.5)

  -- Medium frequency hills for variation (reduced from 20 to 4)
  height = height + 4 * (lovr.math.noise(x * 0.012, z * 0.012) - 0.5)

  -- Smaller hills for detail (reduced from 10 to 2)
  height = height + 2 * (lovr.math.noise(x * 0.025, z * 0.025) - 0.5)

  -- Fine detail for texture (reduced from 5 to 1)
  height = height + 1 * (lovr.math.noise(x * 0.08, z * 0.08) - 0.5)

  -- Ensure minimum height of 0 (ground level)
  local finalHeight = math.max(0, height)

  -- Debug: Log first few height function calls to see what LOVR is asking for
  if _G.terrainHeightCallCount <= 10 then
    print("DEBUG: Height function call #" .. _G.terrainHeightCallCount ..
      " at (" .. string.format("%.3f", x) .. ", " .. string.format("%.3f", z) ..
      ") = " .. string.format("%.3f", finalHeight))
  end

  return finalHeight
end

-- Initialize infinite terrain tile system
function createTerrain()
  print("Initializing infinite terrain tile system...")

  -- Initialize tile management variables
  terrainTiles = {}
  activeTiles = {}
  lastPlayerTileX = nil
  lastPlayerTileZ = nil

  -- Test height function at key points to verify it's working
  print("DEBUG: Testing terrain height function...")
  local testPositions = { { 0, 0 }, { 100, 0 }, { 0, 100 }, { -100, 0 }, { 0, -100 } }
  for i, pos in ipairs(testPositions) do
    local height = terrainHeightFunction(pos[1], pos[2])
    print("  Height at (" .. pos[1] .. ", " .. pos[2] .. "): " .. string.format("%.3f", height))
  end

  print("Infinite terrain system initialized successfully!")
  print("Tile size: " .. tileSize .. "x" .. tileSize .. " units")
  print("Tile subdivisions: " .. tileSubdivisions)
  print("Terrain render distance: " .. terrainRenderDistance .. " units")
  print("Terrain load distance: " .. terrainLoadDistance .. " units")

  -- Initial tiles will be created when player position is first available
end

-- Function to get terrain height at any world position (for object placement)
-- Now works with infinite coordinates since we have infinite terrain tiles
function getTerrainHeight(x, z)
  -- Use the same height function as both physics and graphics
  -- No bounds checking needed with infinite terrain
  return terrainHeightFunction(x, z)
end

-- Function to get physics collision height (simplified approach)
function getPhysicsTerrainHeight(x, z)
  local visualHeight = getTerrainHeight(x, z)
  -- Now that terrain collision is fixed, spawn at proper height
  return visualHeight + 0.1 -- Just slightly above terrain to prevent clipping
end

-- Function to get safe spawn height (at least 1 meter above terrain)
function getSafeSpawnHeight(x, z)
  local terrainHeight = getTerrainHeight(x, z)
  local safeHeight = terrainHeight + 1.0 -- Always 1 meter above terrain for safe spawning

  -- Debug print occasionally to verify safe spawning
  if math.random() < 0.1 then -- 10% chance to print
    print("DEBUG: Safe spawn at (" .. string.format("%.1f", x) .. ", " .. string.format("%.1f", z) ..
      ") - Terrain: " .. string.format("%.2f", terrainHeight) ..
      " -> Safe: " .. string.format("%.2f", safeHeight))
  end

  return safeHeight
end

-- Debug function to test terrain physics vs graphics alignment with tile system
function debugTerrainAlignment(testX, testZ)
  if not player then
    print("DEBUG: player is nil!")
    return 999
  end

  -- Get expected height from height function
  local expectedHeight = terrainHeightFunction(testX, testZ)

  -- Find which tile this position belongs to
  local tileX, tileZ = worldToTileCoords(testX, testZ)
  local tileKey = getTileKey(tileX, tileZ)
  local tile = terrainTiles[tileKey]

  -- Debug terrain tile info
  print("DEBUG: Testing position (" .. testX .. ", " .. testZ .. ")")
  print("DEBUG: Belongs to tile (" .. tileX .. ", " .. tileZ .. ")")
  print("DEBUG: Tile exists: " .. tostring(tile ~= nil))
  if tile and tile.collider then
    local tx, ty, tz = tile.collider:getPosition()
    -- Convert coordinates to numbers to avoid concatenation errors
    local posX = tonumber(tx) or 0
    local posY = tonumber(ty) or 0
    local posZ = tonumber(tz) or 0
    print("DEBUG: Tile collider position: (" ..
      string.format("%.3f", posX) .. ", " .. string.format("%.3f", posY) .. ", " .. string.format("%.3f", posZ) .. ")")
    print("DEBUG: Tile collider kinematic: " .. tostring(tile.collider:isKinematic()))
  else
    print("DEBUG: Tile not loaded or has no collider!")
  end

  -- Test physics collision by raycasting downward from high above
  local rayStartY = 200 -- Start high above any possible terrain
  local hitFound = false
  local physicsHeight = 0
  local hitCount = 0

  -- Raycast downward to find the terrain surface
  world:raycast(testX, rayStartY, testZ, testX, -100, testZ, nil, function(shape, x, y, z, nx, ny, nz)
    hitCount = hitCount + 1
    -- Convert coordinates to numbers to avoid concatenation errors
    local hitX = tonumber(x) or 0
    local hitY = tonumber(y) or 0
    local hitZ = tonumber(z) or 0
    print("DEBUG: Raycast hit #" ..
      hitCount ..
      " at (" ..
      string.format("%.3f", hitX) .. ", " .. string.format("%.3f", hitY) .. ", " .. string.format("%.3f", hitZ) .. ")")

    if shape and shape.getCollider then
      local collider = shape:getCollider()
      local userData = collider:getUserData()
      print("DEBUG: Hit collider type: " .. (userData and userData.type or "unknown"))

      if userData and userData.type == "terrain" then
        physicsHeight = hitY
        hitFound = true
        print("DEBUG: Found terrain hit at height: " .. string.format("%.3f", hitY))
        return false -- Stop raycast at first terrain hit
      end
    end
  end)

  print("DEBUG: Total raycast hits: " .. hitCount)

  if not hitFound then
    print("DEBUG: No terrain hit found at (" .. testX .. ", " .. testZ .. ")")
    -- Try a different approach - test with a falling sphere
    print("DEBUG: Trying falling sphere test...")
    local testSphere = world:newSphereCollider(testX, rayStartY, testZ, 0.1)
    testSphere:setLinearVelocity(0, -50, 0)

    -- Step physics a few times to let it fall
    for i = 1, 50 do
      world:update(0.02)         -- 20ms steps
      local sx, sy, sz = testSphere:getPosition()
      if sy < -50 then break end -- Stop if it falls too far
    end

    local finalX, finalY, finalZ = testSphere:getPosition()
    testSphere:destroy()

    print("DEBUG: Sphere ended at: (" .. finalX .. ", " .. finalY .. ", " .. finalZ .. ")")

    -- Calculate the difference between expected and physics collision for offset tracking
    if finalY > 0 then
      local physicsOffset = finalY - expectedHeight
      print("DEBUG: Physics offset detected: " .. string.format("%.3f", physicsOffset) .. " units")

      -- Store this offset globally for potential correction
      if not _G.terrainPhysicsOffset then
        _G.terrainPhysicsOffset = physicsOffset
        print("DEBUG: Stored terrain physics offset for correction: " .. string.format("%.3f", physicsOffset))
      end
    end

    return 999
  end

  print("DEBUG TERRAIN ALIGNMENT:")
  print("  Test position: (" .. testX .. ", " .. testZ .. ")")
  print("  Expected height: " .. string.format("%.3f", expectedHeight))
  print("  Physics height: " .. string.format("%.3f", physicsHeight))
  print("  Difference: " .. string.format("%.3f", math.abs(expectedHeight - physicsHeight)))

  -- Also test what our height function returns at a few different coordinate interpretations
  print("  Height function tests:")
  print("    Normal: " .. string.format("%.3f", terrainHeightFunction(testX, testZ)))
  print("    Flipped Z: " .. string.format("%.3f", terrainHeightFunction(testX, -testZ)))
  print("    Flipped X: " .. string.format("%.3f", terrainHeightFunction(-testX, testZ)))
  print("    Both flipped: " .. string.format("%.3f", terrainHeightFunction(-testX, -testZ)))

  return math.abs(expectedHeight - physicsHeight)
end

-- ============================================================================
-- HOUSE MANAGEMENT FUNCTIONS
-- ============================================================================

-- Function to update house colliders based on player distance
function updateHouseColliders()
  if not player or not houses then return end

  local playerX, playerY, playerZ = player:getPosition()
  local collidersCreated = 0
  local collidersDestroyed = 0

  for _, house in ipairs(houses) do
    local distance = math.sqrt((house.x - playerX) ^ 2 + (house.z - playerZ) ^ 2)

    if distance <= houseColliderDistance then
      -- Player is close - create collider if it doesn't exist
      if not house.hasCollider then
        house.collider = world:newBoxCollider(house.x, house.y, house.z, house.width, house.height, house.depth)
        house.collider:setKinematic(true) -- Static house
        house.hasCollider = true
        collidersCreated = collidersCreated + 1
      end
    else
      -- Player is far - destroy collider if it exists
      if house.hasCollider and house.collider then
        house.collider:destroy()
        house.collider = nil
        house.hasCollider = false
        collidersDestroyed = collidersDestroyed + 1
      end
    end
  end

  -- Debug: Print collider changes occasionally
  if (collidersCreated > 0 or collidersDestroyed > 0) and math.random() < 0.1 then
    print("House colliders - Created: " .. collidersCreated .. ", Destroyed: " .. collidersDestroyed)
  end
end

-- ============================================================================
-- ROCK COLLIDER MANAGEMENT FUNCTIONS
-- ============================================================================

-- Function to update rock colliders based on player distance
function updateRockColliders()
  if not player or not rockModel then return end

  local playerX, playerY, playerZ = player:getPosition()
  local collidersCreated = 0
  local collidersDestroyed = 0

  for _, rock in ipairs(rocks) do
    local distance = math.sqrt((rock.x - playerX) ^ 2 + (rock.z - playerZ) ^ 2)

    if distance <= rockColliderDistance then
      -- Player is close - create collider if it doesn't exist
      if not rock.hasCollider then
        rock.collider = world:newMeshCollider(rockModel)
        rock.collider:setPosition(rock.x, rock.y, rock.z)
        rock.collider:setKinematic(true) -- Static rock
        rock.collider:setOrientation(0, rock.rotation, 0)
        rock.hasCollider = true
        collidersCreated = collidersCreated + 1
      end
    else
      -- Player is far - destroy collider if it exists
      if rock.hasCollider and rock.collider then
        rock.collider:destroy()
        rock.collider = nil
        rock.hasCollider = false
        collidersDestroyed = collidersDestroyed + 1
      end
    end
  end

  -- Debug: Print collider changes occasionally
  if (collidersCreated > 0 or collidersDestroyed > 0) and math.random() < 0.1 then
    print("Rock colliders - Created: " .. collidersCreated .. ", Destroyed: " .. collidersDestroyed)
  end
end

-- ============================================================================
-- MAIN GAME CODE
-- ============================================================================
-- Render functions for different object types with custom shadow parameters
local function render_terrain(pass)
  -- Use the new tile-based terrain rendering system
  renderTerrainTiles(pass)
end

local function render_players_and_npcs(pass)
  -- Draw other players if in multiplayer mode
  if (multiplayerMode == "host" or multiplayerMode == "client") and multiplayerClient then
    multiplayerClient:drawOtherPlayers(pass)
  end
  drawNPCs(pass)
end

local function render_rocks(pass)
  -- Draw rocks with render distance culling
  if rockModel and rocks then
    pass:setColor(1, 1, 1) -- White color for natural rock appearance

    -- Get player position for distance calculation
    local playerX, playerY, playerZ = 0, 0, 0
    if player then
      playerX, playerY, playerZ = player:getPosition()
    end

    local rocksRendered = 0
    local rocksWithColliders = 0

    for _, rock in ipairs(rocks) do
      -- Calculate distance from player to rock
      local distance = math.sqrt((rock.x - playerX) ^ 2 + (rock.z - playerZ) ^ 2)

      -- Only render if within render distance
      if distance <= renderDistance then
        pass:push()
        pass:translate(rock.x, rock.y, rock.z)
        pass:rotate(rock.rotation, 0, 1, 0)            -- Apply random rotation
        pass:scale(rock.scale, rock.scale, rock.scale) -- Apply random scale
        pass:draw(rockModel)
        pass:pop()
        rocksRendered = rocksRendered + 1

        -- Count rocks with active colliders
        if rock.hasCollider then
          rocksWithColliders = rocksWithColliders + 1
        end
      end
    end

    -- Debug: Print rock count occasionally (1% chance per frame)
    if math.random() < 0.01 then
      print("Rocks rendered: " ..
        rocksRendered ..
        "/" .. #rocks .. " (within " .. renderDistance .. " units, " .. rocksWithColliders .. " with colliders)")
    end
  end
end

local function render_houses(pass)
  -- Draw houses with render distance culling - uses custom shadow parameters
  if houses then
    -- Get player position for distance calculation
    local playerX, playerY, playerZ = 0, 0, 0
    if player then
      playerX, playerY, playerZ = player:getPosition()
    end

    local housesRendered = 0
    local housesWithColliders = 0

    for _, house in ipairs(houses) do
      -- Calculate distance from player to house
      local distance = math.sqrt((house.x - playerX) ^ 2 + (house.z - playerZ) ^ 2)

      -- Only render if within render distance
      if distance <= renderDistance then
        pass:setColor(house.color[1], house.color[2], house.color[3])
        pass:box(house.x, house.y, house.z, house.width, house.height, house.depth)
        housesRendered = housesRendered + 1

        -- Count houses with active colliders
        if house.hasCollider then
          housesWithColliders = housesWithColliders + 1
        end
      end
    end

    -- Debug: Print house count occasionally (1% chance per frame)
    if math.random() < 0.01 then
      print("Houses rendered: " ..
        housesRendered ..
        "/" .. #houses .. " (within " .. renderDistance .. " units, " .. housesWithColliders .. " with colliders)")
    end
  end
end

local function render_misc_objects(pass)
  -- Draw some small reference objects near spawn
  pass:setColor(0.8, 0.8, 0.8) -- Light gray
  for i = -3, 3 do
    for j = -3, 3 do
      if i % 2 == 0 and j % 2 == 0 and not (i == 0 and j == 0) then
        pass:cube(i * 4, 2, j * 4, 2) -- Made much bigger and taller: 2x2x2 instead of 0.5x0.5x0.5
      end
    end
  end
end

-- Function to render light posts
local function render_light_posts(pass)
  if not lightPosts then return end

  -- Get player position for distance calculation
  local playerX, playerY, playerZ = 0, 0, 0
  if player then
    playerX, playerY, playerZ = player:getPosition()
  end

  globalLightsRendered = 0 -- Reset the global counter

  for _, lightPost in ipairs(lightPosts) do
    -- Calculate distance from player to light post
    local distance = math.sqrt((lightPost.x - playerX) ^ 2 + (lightPost.z - playerZ) ^ 2)

    -- Only render if within render distance
    if distance <= renderDistance then
      -- Draw magical crystal base (dark crystal material)
      pass:setColor(0.1, 0.1, 0.2)
      pass:box(lightPost.x, lightPost.y - 0.8, lightPost.z, 0.4, 0.6, 0.4)

      -- Draw crystal stem (slightly glowing)
      pass:setColor(0.2, 0.2, 0.4)
      pass:box(lightPost.x, lightPost.y - 0.3, lightPost.z, 0.2, 0.8, 0.2)

      -- Draw bright magical orb (main light source)
      pass:setColor(lightPost.color[1], lightPost.color[2], lightPost.color[3])
      pass:sphere(lightPost.x, lightPost.y + 0.2, lightPost.z, 0.7)

      -- Add a smaller inner glow effect
      pass:setColor(
        math.min(1, lightPost.color[1] * 1.5),
        math.min(1, lightPost.color[2] * 1.5),
        math.min(1, lightPost.color[3] * 1.5)
      )
      pass:sphere(lightPost.x, lightPost.y + 0.2, lightPost.z, 0.4)

      globalLightsRendered = globalLightsRendered + 1
    end
  end

  -- Debug: Print light post count occasionally
  if math.random() < 0.01 then -- 1% chance per frame
    print("Light posts rendered: " .. globalLightsRendered .. "/" .. #lightPosts)
  end
end

-- Combined render function for compatibility
local function render_scene(pass)
  render_terrain(pass)
  render_players_and_npcs(pass)
  render_rocks(pass)
  render_houses(pass)
  render_misc_objects(pass)
end

local function lighting_shader()
  local vs = [[
  vec4 lovrmain() {
    return Projection * View * Transform * VertexPosition;
  }
]]

  local fs = [[
  // Multiple lights system (no shadows for simplicity)
  uniform int numLights;
  uniform vec3 lightPositions[16];
  uniform vec3 lightColors[16];
  uniform float lightIntensities[16];
  uniform float lightRanges[16];

  vec4 multiLightLighting(vec3 worldPos, vec3 normal) {
    vec4 baseColor = Color * getPixel(ColorTexture, UV);
    vec4 ambience = vec4(0.05, 0.05, 0.1, 1.0);
    vec3 totalDiffuse = vec3(0.0);

    // Calculate lighting from all light posts
    for (int i = 0; i < numLights && i < 16; i++) {
      vec3 lightDir = lightPositions[i] - worldPos;
      float distance = length(lightDir);

      // Skip if beyond light range
      if (distance > lightRanges[i]) continue;

      lightDir = normalize(lightDir);

      // Calculate attenuation (light falloff with distance)
      float attenuation = 1.0 - (distance / lightRanges[i]);
      attenuation = attenuation * attenuation; // Quadratic falloff

      // Calculate diffuse lighting
      float diff = max(dot(normal, lightDir), 0.0);
      vec3 diffuse = diff * lightColors[i] * lightIntensities[i] * attenuation;

      totalDiffuse += diffuse;
    }

    return baseColor * (ambience + vec4(totalDiffuse, 0.0));
  }

  vec4 lovrmain() {
    vec3 normal = normalize(Normal);
    return multiLightLighting(PositionWorld, normal);
  }
]]

  return lovr.graphics.newShader(vs, fs, {})
end

local function render_shadow_map_with_params(draw, near_plane, far_plane, radius)
  local projection
  if light_orthographic then
    projection = mat4():orthographic(-radius, radius, -radius, radius, near_plane, far_plane)
  else
    projection = mat4():perspective(shadow_fov, 1, near_plane)
  end

  -- Make light look at a point relative to the player position instead of fixed origin
  local playerX, playerY, playerZ = 0, 0, 0
  if gameState == "playing" and player then
    playerX, playerY, playerZ = player:getPosition()
  end
  local lightTarget = vec3(playerX, playerY, playerZ)
  local view = mat4():lookAt(light_pos, lightTarget)

  light_space_matrix = mat4(projection):mul(view)

  shadow_map_pass:reset()
  shadow_map_pass:setProjection(1, projection)
  shadow_map_pass:setViewPose(1, view, true)
  if light_orthographic then
    -- Note for ortho projection with a far plane the depth coord is reversed
    shadow_map_pass:setDepthTest('lequal')
  end

  if debug_render_from_light then
    shadow_map_pass:setShader(shader)
    shadow_map_pass:send('lightPos', light_pos)
  end

  draw(shadow_map_pass)
end

-- Original function using default parameters
local function render_shadow_map(draw)
  render_shadow_map_with_params(draw, shadow_near_plane, shadow_far_plane, shadow_radius)
end

local function render_lighting_pass(draw)
  lighting_pass:reset()

  lighting_pass:setViewPose(1, camera.transform)
  local width, height = lovr.system.getWindowDimensions()
  local aspect = width / height
  local fov_h = 2 * math.atan(math.tan(camera.fov / 2) * aspect)
  local half_fov_h = fov_h / 2
  local half_fov_v = camera.fov / 2

  lighting_pass:setProjection(1, -half_fov_h, half_fov_h, half_fov_v, -half_fov_v, 0.01, 0.0)

  lighting_pass:setShader(shader)
  lighting_pass:setSampler(shadow_map_sampler)
  lighting_pass:send('shadowMapTexture', shadow_map_texture)
  lighting_pass:send('lightPos', light_pos)
  lighting_pass:send('lightSpaceMatrix', light_space_matrix)
  lighting_pass:send('lightOrthographic', light_orthographic)
  lighting_pass:send('lightIntensity', light_intensity)
  lighting_pass:send('lightColor', light_color)
  draw(lighting_pass)
  lighting_pass:setShader()
end

local function debug_passes(pass)
  pass:setDepthWrite(false)

  if debug_render_from_light then
    -- Debug mode: show scene from light's perspective
    pass:fill(shadow_map_texture)
  else
    -- Normal mode: show the properly lit scene with shadows
    pass:fill(render_texture)
    if debug_show_shadow_map then
      -- Debug overlay: show shadow map in corner
      local width, height = lovr.system.getWindowDimensions()
      pass:setViewport(0, 0, width / 4, height / 4)
      pass:fill(shadow_map_texture)
    end
  end
end

function lovr.load()
  -- Set up multi-light shader (no shadows)
  shader = lighting_shader()
  lovr.graphics.setBackgroundColor(0x4782B3)
  -- Game state management
  gameState = "playing" -- "playing", "menu", "ip_input", "settings"
  menuSelection = 1
  menuOptions = { "Resume", "Host Game", "Join Game", "Change Server IP", "Settings", "Quit" }

  -- Settings menu variables
  settingsSelection = 1
  settingsOptions = { "Render Distance", "Back to Main Menu" }
  sliderActive = false -- Whether the slider is being actively adjusted
  minRenderDistance = 50
  maxRenderDistance = 1000

  -- ENet Multiplayer setup
  multiplayerMode = "single" -- "single", "host", "client"
  multiplayerClient = nil
  multiplayerServer = nil
  serverAddress = "localhost"

  -- HUD setup with smaller font
  hudFont = lovr.graphics.newFont(8) -- Even smaller font size
  if hudFont.setPixelDensity then
    hudFont:setPixelDensity(2)       -- Higher pixel density for sharper text
  end
  -- Load the custom terrain model

  -- Load player model
  playerModel = lovr.graphics.newModel("characterModel/scene.gltf")

  --load the rock model
  rockModel = lovr.graphics.newModel("rockModel/scene.gltf")

  -- Load separate NPC model (same file but different instance for independent animation)
  npcModel = lovr.graphics.newModel("characterModel/scene.gltf")

  serverPort = 6789
  lastNetworkUpdate = 0
  networkUpdateRate = 1 / 60 -- 60 Hz for realistic feel

  -- NPC network synchronization
  lastNPCNetworkUpdate = 0
  npcNetworkUpdateRate = 1 / 60 -- 60 Hz for NPCs (same as players)

  -- IP Input system
  ipInputMode = false
  ipInputText = serverAddress
  ipInputCursor = string.len(ipInputText)

  -- Global ping display
  pingText = ""
  pingDisplayTime = 0

  --players last position before they stop moving and are on the ground
  playerLastPosition = nil
  playerOnGround = false
  playerPositionLocked = false

  -- Ground detection debug variables
  groundDebug = {
    distance = 0,
    hits = 0,
    slope = 0
  }

  -- Inventory system
  inventory = {}
  selectedSlot = 1 -- Currently selected inventory slot (1-8)

  -- Initialize empty inventory with 8 slots
  for i = 1, 8 do
    inventory[i] = {
      item = nil, -- Item name or nil if empty
      count = 0,  -- Item count
      icon = nil  -- Item icon/texture (placeholder for now)
    }
  end

  lovr.mouse.setRelativeMode(true)
  worldsettings = {
    maxColliders = 16384,
    maxPenetration = 0.0

  }
  -- Create physics world with traditional settings first (try simple approach)
  world = lovr.physics.newWorld(worldsettings)
  world:setGravity(0, -9.81, 0)
  -- Try setting world contact properties to prevent phasing
  world:setLinearDamping(0.01)
  world:setAngularDamping(0.01)

  -- Global render distance configuration
  renderDistance = 500 -- Master render distance for all objects

  -- Initialize new infinite terrain tile system
  createTerrain()

  -- Calculate spawn height (after terrain is created)
  local terrainHeight = getTerrainHeight(0, 0)
  print("DEBUG: Terrain height at spawn:", terrainHeight)

  -- Use standardized safe spawn height (1 meter above terrain)
  local spawnHeight = getSafeSpawnHeight(0, 0)
  print("DEBUG: Safe spawn height (1m above terrain):", spawnHeight)

  -- Player physics body (cylinder for character controller) - VERTICAL orientation
  player = world:newBoxCollider(0, spawnHeight, 0, boxColliderWidth, boxColliderHeight, boxColliderDepth)
  -- Box colliders are naturally vertical (Y-axis aligned), no rotation needed
  player:setLinearDamping(1.0)  -- Reasonable damping for 70kg human
  player:setAngularDamping(5.0) -- Prevent spinning but allow movement
  player:setFriction(1.0)       -- Maximum friction to reduce sliding

  -- Set additional collision properties to prevent phasing
  player:setRestitution(0) -- Bouncy for fun physics

  -- Set heavy mass and realistic inertia for better gravity response
  player:setMass(playerNPCMass)
  player:setInertia(playerNPCInertia[1], playerNPCInertia[2], playerNPCInertia[3], playerNPCInertia[4],
    playerNPCInertia[5], playerNPCInertia[6])

  -- Mark this as the local player collider
  player:setUserData({ type = "local_player" })

  -- Camera/player setup
  camera = {
    transform = lovr.math.newMat4(),
    position = lovr.math.newVec3(0, spawnHeight + cameraHeightOffset, 0), -- Start at spawn height
    movespeed = 2.5,                                                      -- Reduced to 0.5x (5 * 0.5 = 2.5)
    pitch = 0,
    yaw = 0,
    fov = math.pi / 2
  }

  -- Generate initial terrain tiles around spawn point
  print("Generating initial terrain tiles around spawn...")
  updateTerrainTiles()

  -- Generate house-sized cubes across the terrain (deterministic placement)
  houses = {}
  houseColliderDistance = 80 -- Only create colliders for houses within this distance

  -- Use LÖVR's math.setRandomSeed for deterministic placement
  lovr.math.setRandomSeed(12345)                   -- Fixed seed for consistent placement every time

  for i = 1, 1500 do                               -- Generate 1500 houses for a dense city
    local x = (lovr.math.random() - 0.5) * 8000    -- Spread across 8km range
    local z = (lovr.math.random() - 0.5) * 8000
    local houseSize = 8 + lovr.math.random() * 4   -- House size between 8-12 units
    local houseHeight = 6 + lovr.math.random() * 6 -- Height between 6-12 units

    -- Store house data (without collider initially)
    local houseGroundHeight = getTerrainHeight(x, z)
    table.insert(houses, {
      x = x,
      y = houseGroundHeight + houseHeight / 2, -- Position house base on visual terrain surface
      z = z,
      width = houseSize,
      height = houseHeight,
      depth = houseSize,
      color = {
        lovr.math.random() * 0.5 + 0.3, -- Red component (0.3-0.8)
        lovr.math.random() * 0.5 + 0.3, -- Green component (0.3-0.8)
        lovr.math.random() * 0.5 + 0.3  -- Blue component (0.3-0.8)
      },
      collider = nil,                   -- Will be created when player gets close
      hasCollider = false
    })
  end

  -- Keep the deterministic seed - do NOT reset it to current time
  -- This ensures houses appear in the same locations every launch

  -- ============================================================================
  -- ROCK SYSTEM - Procedurally placed rocks with distance-based colliders
  -- ============================================================================
  rocks = {}
  rockColliderDistance = 50 -- Only create colliders for rocks within this distance

  -- Generate rock positions (without colliders initially)
  for i = 1, 10000 do -- Generate 10000 rocks across the map
    local attempts = 0
    local rockX, rockZ
    local validPosition = false

    repeat
      rockX = (lovr.math.random() - 0.5) * 6000 -- Spread across 6km range (smaller than houses)
      rockZ = (lovr.math.random() - 0.5) * 6000
      attempts = attempts + 1

      -- Check if rock position is clear of houses
      validPosition = true
      for _, house in ipairs(houses) do
        local distance = math.sqrt((rockX - house.x) ^ 2 + (rockZ - house.z) ^ 2)
        if distance < (house.width / 2 + 3) then -- Need at least 3 units clearance from house edge
          validPosition = false
          break
        end
      end

      -- Also check distance from other rocks to avoid clustering
      if validPosition then
        for _, existingRock in ipairs(rocks) do
          local distance = math.sqrt((rockX - existingRock.x) ^ 2 + (rockZ - existingRock.z) ^ 2)
          if distance < 8 then -- Minimum 8 units between rocks
            validPosition = false
            break
          end
        end
      end
    until validPosition or attempts > 100 -- Give up after 100 attempts

    if validPosition then
      local rockY = getTerrainHeight(rockX, rockZ) + 0.1 -- 0.1 meters above visual terrain surface
      local randomRotation = lovr.math.random() * math.pi * 2
      local randomScale = 0.8 + lovr.math.random() * 0.7

      -- Store rock data (without collider initially)
      table.insert(rocks, {
        x = rockX,
        y = rockY,
        z = rockZ,
        rotation = randomRotation,
        scale = randomScale,
        collider = nil, -- Will be created when player gets close
        hasCollider = false
      })
    end
  end

  print("Generated " .. #rocks .. " rock positions across the map")

  -- ============================================================================
  -- LIGHT POST SYSTEM - Street lights scattered around the map
  -- ============================================================================

  -- Function to generate light posts on top of rocks
  function generateLightPosts()
    lightPosts = {}

    -- Place lights on top of rocks instead of in a grid pattern
    local lightHeightAboveRock = 3 -- How many units above the rock to place the light
    local rocksWithLights = 0

    for _, rock in ipairs(rocks) do
      -- Check if rock is far enough from houses (only if lightsOnAllRocks is false)
      local validPosition = true

      if not lightsOnAllRocks then
        -- Only avoid placing lights on rocks too close to houses if lightsOnAllRocks is false
        for _, house in ipairs(houses) do
          local distance = math.sqrt((rock.x - house.x) ^ 2 + (rock.z - house.z) ^ 2)
          if distance < (house.width / 2 + 5) then -- Need 5 units clearance from houses
            validPosition = false
            break
          end
        end
      end

      if validPosition then
        -- Position light above the rock
        -- rock.y is already positioned on terrain, so add height above that
        local lightY = rock.y + lightHeightAboveRock + (rock.scale or 1) * 2 -- Account for rock scale

        table.insert(lightPosts, {
          x = rock.x,
          y = lightY,
          z = rock.z,
          intensity = light_intensity * lightBrightness * (0.8 + lovr.math.random() * 0.4), -- Vary intensity
          color = {
            light_color[1] * (0.9 + lovr.math.random() * 0.2),
            light_color[2] * (0.9 + lovr.math.random() * 0.2),
            light_color[3] * (0.9 + lovr.math.random() * 0.2)
          },
          range = lightRange + lovr.math.random() * 10, -- Light range with some variation
          rockIndex = _                                 -- Keep reference to which rock this light is on
        })

        rocksWithLights = rocksWithLights + 1

        -- Limit total number of lights for performance
        if #lightPosts >= maxLights then
          break
        end
      end
    end

    local filterStatus = lightsOnAllRocks and "all rocks" or "rocks away from houses"
    print("Generated " ..
      #lightPosts ..
      " light posts on " .. rocksWithLights .. " rocks (total rocks: " .. #rocks .. ", mode: " .. filterStatus .. ")")
  end

  -- Generate the light posts
  generateLightPosts()

  -- ============================================================================
  -- NPC SYSTEM - Walking NPCs that avoid houses
  -- ============================================================================
  npcs = {}

  -- Only generate NPCs if we're the host or in single player mode
  -- Clients will receive NPC data from the host instead
  if multiplayerMode == "single" or multiplayerMode == "host" then
    -- NPC configuration (global so updateNPCs can access it)
    npcConfig = {
      count = 25,                -- Number of NPCs to spawn
      maxSpeed = 1.2,            -- Maximum movement speed
      avoidanceRadius = 4.0,     -- How far ahead to look for obstacles
      personalSpaceRadius = 1.5, -- Minimum distance between NPCs
      wanderRadius = 500,        -- How far NPCs wander from spawn point (increased from 15 to 100)
      steerStrength = 3.0,       -- How strongly NPCs steer to avoid obstacles
      colors = {                 -- Different colors for NPCs
        { 1.0, 0.3, 0.3 },       -- Red
        { 0.3, 1.0, 0.3 },       -- Green
        { 0.3, 0.3, 1.0 },       -- Blue
        { 1.0, 1.0, 0.3 },       -- Yellow
        { 1.0, 0.3, 1.0 },       -- Magenta
        { 0.3, 1.0, 1.0 },       -- Cyan
      }
    }

    -- Create NPCs
    for i = 1, npcConfig.count do
      -- Find a safe spawn location away from houses
      local spawnX, spawnZ
      local attempts = 0
      repeat
        spawnX = (lovr.math.random() - 0.5) * 200 -- Spawn in 200x200 area around origin
        spawnZ = (lovr.math.random() - 0.5) * 200
        attempts = attempts + 1

        -- Check if spawn location is clear of houses (simple distance check)
        local clearSpace = true
        for _, house in ipairs(houses) do
          local distance = math.sqrt((spawnX - house.x) ^ 2 + (spawnZ - house.z) ^ 2)
          if distance < house.width * 0.8 then -- Too close to a house
            clearSpace = false
            break
          end
        end

        if clearSpace then break end
      until attempts > 50 -- Give up after 50 attempts

      -- Create physics body for NPC (positioned at safe height above terrain)
      local npcSpawnHeight = getSafeSpawnHeight(spawnX, spawnZ)
      local npcBody = world:newBoxCollider(spawnX, npcSpawnHeight, spawnZ, boxColliderWidth,
        boxColliderHeight, boxColliderDepth)
      -- Box colliders are naturally vertical (Y-axis aligned), no rotation needed
      npcBody:setLinearDamping(1.0)  -- Reasonable damping for 70kg human
      npcBody:setAngularDamping(5.0) -- Prevent spinning but allow movement
      npcBody:setFriction(0.3)       -- Lower friction for easier movement
      npcBody:setRestitution(0)      -- Bouncy for fun physics

      -- Set heavy mass and realistic inertia for better gravity response (same as player)
      npcBody:setMass(playerNPCMass)
      npcBody:setInertia(playerNPCInertia[1], playerNPCInertia[2], playerNPCInertia[3], playerNPCInertia[4],
        playerNPCInertia[5], playerNPCInertia[6])

      -- Mark this as an NPC collider
      npcBody:setUserData({ type = "npc", id = i })

      -- Create NPC data structure
      local npc = {
        body = npcBody,
        id = i, -- Add unique ID for multiplayer synchronization
        spawnPoint = { x = spawnX, z = spawnZ },
        targetPoint = { x = spawnX, z = spawnZ },
        velocity = lovr.math.newVec3(0, 0, 0),
        desiredVelocity = lovr.math.newVec3(0, 0, 0),
        avoidanceForce = lovr.math.newVec3(0, 0, 0),
        separationForce = lovr.math.newVec3(0, 0, 0),
        wanderAngle = lovr.math.random() * math.pi * 2,
        wanderChangeTimer = 0,
        color = npcConfig.colors[(i - 1) % #npcConfig.colors + 1],
        state = "wandering", -- "wandering", "avoiding", "returning"
        stuckTimer = 0,      -- Detect if NPC gets stuck
        lastPosition = lovr.math.newVec3(spawnX, 5.5, spawnZ)
      }

      table.insert(npcs, npc)
    end

    -- End of NPC generation (now for all clients)
  end
end

function lovr.update(dt)
  -- Remove the single orbiting light - it will be replaced with static light posts
  -- (No longer updating light_pos here)

  -- Only update game physics when playing
  if gameState ~= "playing" then
    return
  end

  -- Update ENet multiplayer
  if multiplayerMode == "host" and multiplayerServer then
    multiplayerServer:update()

    -- No ghost collider system anymore - clients will send push events directly
  end

  if (multiplayerMode == "host" or multiplayerMode == "client") and multiplayerClient then
    multiplayerClient:update()

    -- Send player updates to other clients at regular intervals
    if lovr.timer.getTime() - lastNetworkUpdate > networkUpdateRate then
      local px, py, pz = player:getPosition()
      local position = lovr.math.newVec3(px, py, pz)

      -- Check if player is moving forward (pressing 'w')
      local isMovingForward = lovr.system.isKeyDown('w')

      multiplayerClient:sendPlayerUpdate(position, camera.yaw, isMovingForward) -- Send yaw and movement state
      lastNetworkUpdate = lovr.timer.getTime()
    end

    -- Client-side NPC push detection (only for clients, not host)
    if multiplayerMode == "client" then
      -- Debug: Check if we have NPCs from host
      if not multiplayerClient.npcsFromHost then
        if math.random() < 0.01 then -- 1% chance to print
          print("DEBUG: Client has no npcsFromHost data")
        end
      else
        local npcCount = 0
        for _ in pairs(multiplayerClient.npcsFromHost) do npcCount = npcCount + 1 end

        if math.random() < 0.01 then -- 1% chance to print
          print("DEBUG: Client checking " .. npcCount .. " physics NPCs for push detection")
        end

        for npcId, npc in pairs(multiplayerClient.npcsFromHost) do
          -- Use physics body position if available, otherwise fall back to stored position
          local npcX, npcY, npcZ
          if npc.body then
            npcX, npcY, npcZ = npc.body:getPosition()
          else
            npcX, npcY, npcZ = npc.position.x, npc.position.y, npc.position.z
          end

          -- Check distance between client player and this NPC
          local px, py, pz = player:getPosition()
          local distance = math.sqrt((px - npcX) ^ 2 + (py - npcY) ^ 2 + (pz - npcZ) ^ 2)

          -- Debug: Print distance for closest NPC
          if distance < 3.0 and math.random() < 0.1 then -- Within 3 units, 10% chance to print
            print("DEBUG: Client distance to physics NPC " .. npcId .. ": " .. string.format("%.2f", distance))
          end

          -- If client is close enough to NPC and moving, send a push event to host
          if distance < 1.5 then -- Increased from 1.0 to 1.5 for easier testing
            local vx, vy, vz = player:getLinearVelocity()
            local speed = math.sqrt(vx ^ 2 + vy ^ 2 + vz ^ 2)

            if math.random() < 0.1 then -- 10% chance to print when close
              print("DEBUG: Close to physics NPC " .. npcId .. ", speed: " .. string.format("%.2f", speed))
            end

            if speed > 1.0 then                    -- Lowered from 2.0 to 1.0 for easier testing
              -- Calculate push direction from player to NPC
              local pushX = (npcX - px) / distance -- Normalize direction
              local pushZ = (npcZ - pz) / distance

              -- Send push message to host (use physics body position)
              local pushPosition = lovr.math.newVec3(npcX, npcY, npcZ)
              local pushForce = lovr.math.newVec3(pushX * speed * 100, 0, pushZ * speed * 100) -- Increased force multiplier
              multiplayerClient:sendNPCPush(npcId, pushPosition, pushForce)

              print("DEBUG: Client pushing physics NPC " ..
                npcId .. " with force " .. string.format("%.2f,%.2f,%.2f", pushForce.x, pushForce.y, pushForce.z))
            end
          end
        end
      end
    end
  end

  --use terrain height to check if player is on the ground
  if player then
    local playerX, playerY, playerZ = player:getPosition()
    local groundThreshold = 0.53 -- Distance threshold for walking on terrain (realistic value)

    -- Get actual terrain height at player position
    local terrainHeight = getTerrainHeight(playerX, playerZ)
    local groundDistance = playerY - terrainHeight

    -- Clear debug data for this frame
    groundDebug.allHits = {}
    groundDebug.totalRayHits = 1 -- Always have terrain data
    groundDebug.fallbackUsed = false

    -- Store terrain-based ground info
    groundDebug.distance = groundDistance
    groundDebug.terrainHeight = terrainHeight
    groundDebug.playerHeight = playerY
    groundDebug.hits = 1    -- Always have terrain data
    groundDebug.slope = 1.0 -- Assume walkable terrain

    -- Player is on ground if within threshold of terrain
    if groundDistance <= groundThreshold and groundDistance >= -1.0 then
      playerOnGround = true
    else
      playerOnGround = false
    end

    -- Create fake hit data for debug display compatibility
    if not groundDebug.allHits then groundDebug.allHits = {} end
    table.insert(groundDebug.allHits, {
      hitPos = { playerX, terrainHeight, playerZ },
      debugPlayerY = playerY,
      debugHitY = terrainHeight,
      debugComparison = string.format("Terrain: %.2f dist (Player %.2f - Terrain %.2f)", groundDistance, playerY,
        terrainHeight),
      hitShapeType = "terrain_height",
      isBelow = (terrainHeight < playerY + 1.0),
      distance = groundDistance
    })
  end


  -- Initialize playerLastPosition if it's nil
  if player and playerLastPosition == nil then
    local px, py, pz = player:getPosition()
    playerLastPosition = { x = px, y = py, z = pz }
  end

  if playerOnGround == false or lovr.system.isKeyDown('w') == true or lovr.system.isKeyDown('s') == true or lovr.system.isKeyDown('d') == true or lovr.system.isKeyDown('a') == true or lovr.system.isKeyDown('space') == true or lovr.system.isKeyDown('lshift') == true or lovr.system.isKeyDown('rshift') == true then
    local px, py, pz = player:getPosition()
    playerLastPosition = { x = px, y = py, z = pz }
    playerPositionLocked = false
  end

  if playerOnGround == true and lovr.system.isKeyDown('w') == false and lovr.system.isKeyDown('s') == false and lovr.system.isKeyDown('d') == false and lovr.system.isKeyDown('a') == false and lovr.system.isKeyDown('space') == false and lovr.system.isKeyDown('lshift') == false then
    --locks the player in place
    playerPositionLocked = true
    player:setLinearVelocity(0, 0, 0)
    --sets the player's position to the last position
    if playerLastPosition then
      player:setPosition(playerLastPosition.x, playerLastPosition.y, playerLastPosition.z)
    end
  end








  -- Get movement input
  local moveForward = 0
  local moveRight = 0

  if lovr.system.isKeyDown('w') then
    moveForward = moveForward + 1 -- Forward relative to camera
  end
  if lovr.system.isKeyDown('s') then
    moveForward = moveForward - 1 -- Backward relative to camera
  end
  if lovr.system.isKeyDown('d') then
    moveRight = moveRight + 1 -- Right relative to camera
  end
  if lovr.system.isKeyDown('a') then
    moveRight = moveRight - 1 -- Left relative to camera
  end

  -- Apply movement forces if there's input
  if moveForward ~= 0 or moveRight ~= 0 then
    -- Normalize diagonal movement
    local length = math.sqrt(moveForward * moveForward + moveRight * moveRight)
    moveForward = moveForward / length
    moveRight = moveRight / length

    -- Calculate forward and right directions based on camera yaw
    local forwardX = -math.sin(camera.yaw)
    local forwardZ = -math.cos(camera.yaw)
    local rightX = math.cos(camera.yaw)
    local rightZ = -math.sin(camera.yaw)

    -- Combine forward and right movements
    local worldX = moveForward * forwardX + moveRight * rightX
    local worldZ = moveForward * forwardZ + moveRight * rightZ

    -- Check if sprinting (holding shift)
    local isSprinting = lovr.system.isKeyDown('lshift') or lovr.system.isKeyDown('rshift')
    local speedMultiplier = isSprinting and 3.0 or 1.0 -- 3x speed when sprinting

    -- Apply force in world coordinates
    local force = camera.movespeed * speedMultiplier * playerSpeed -- Base force with sprint multiplier
    player:applyForce(worldX * force, 0, worldZ * force)

    -- Debug: Print movement info occasionally
    if math.random() < 0.05 then -- 5% chance per frame when moving
      local vx, vy, vz = player:getLinearVelocity()
      print("DEBUG Player - Force:", string.format("%.0f", force), "Velocity:",
        string.format("%.2f,%.2f,%.2f", vx, vy, vz))
    end
  else
    -- Apply damping when no input to stop sliding
    local vx, vy, vz = player:getLinearVelocity()
    player:applyForce(-vx * 50, 0, -vz * 50) -- Reasonable counter-force for 70kg mass
  end

  -- Update infinite terrain tiles based on player position
  updateTerrainTiles()

  -- Update house colliders based on player distance
  updateHouseColliders()

  -- Update rock colliders based on player distance
  updateRockColliders()

  -- Update physics
  world:update(dt)

  -- Update camera position to follow player (with offset for first person view)
  local playerX, playerY, playerZ = player:getPosition()
  camera.position:set(playerX, playerY + cameraHeightOffset, playerZ) -- Camera positioned 0.75 meters above player center

  -- Rotate player collider to match camera yaw
  player:setOrientation(camera.yaw, 0, 1, 0) -- angle, ax, ay, az format

  -- DEBUG: Check if player is falling through terrain
  local vx, vy, vz = player:getLinearVelocity()
  -- If falling fast


  -- Check if player has fallen below expected terrain
  local expectedHeight = terrainHeightFunction(playerX, playerZ)
  -- 5 units below expected terrain
  if groundDebug.emergencyRespawn == nil then
    groundDebug.emergencyRespawn = false
  end


  -- Emergency respawn if player falls too far
  if playerY < expectedHeight - 0.1 then
    --writes to the ground debug table
    groundDebug.emergencyRespawn = true
    print("EMERGENCY RESPAWN: Moving player back to safe height")
    local safeHeight = getSafeSpawnHeight(playerX, playerZ)
    player:setPosition(playerX, safeHeight, playerZ)
    player:setLinearVelocity(0, 0, 0)
    player:setAngularVelocity(0, 0, 0)
  end



  -- Update camera transform
  camera.transform:identity()
  camera.transform:translate(camera.position)
  camera.transform:rotate(camera.yaw, 0, 1, 0)
  camera.transform:rotate(camera.pitch, 1, 0, 0)

  -- NPC Update Function - Call this from lovr.update()
  -- Only the host should simulate NPCs, clients receive NPC data
  if multiplayerMode == "single" or multiplayerMode == "host" then
    updateNPCs(dt)
  end

  -- Ping display persists until manually cleared with "O" key
end

function lovr.draw(pass)
  lovr.graphics.setBackgroundColor(0, 0, 0) -- black sky

  if gameState == "menu" then
    -- Set up a basic camera for the menu
    pass:push()
    pass:origin()           -- Reset to origin
    pass:translate(0, 0, 0) -- Position at origin
    -- Draw main menu
    drawMainMenu(pass)
    pass:pop()
    return
  elseif gameState == "ip_input" then
    -- Set up a basic camera for the IP input
    pass:push()
    pass:origin()           -- Reset to origin
    pass:translate(0, 0, 0) -- Position at origin
    -- Draw IP input screen
    drawIPInput(pass)
    pass:pop()
    return
  elseif gameState == "settings" then
    -- Set up a basic camera for the settings menu
    pass:push()
    pass:origin()           -- Reset to origin
    pass:translate(0, 0, 0) -- Position at origin
    -- Draw settings menu
    drawSettingsMenu(pass)
    pass:pop()
    return
  end

  -- Set up main camera view with multi-light shader
  pass:push()
  pass:setViewPose(1, camera.transform)

  -- Apply the multi-light shader to the main pass
  pass:setShader(shader)

  -- Send light data to shader (only lights within render distance)
  local playerX, playerY, playerZ = 0, 0, 0
  if player then
    playerX, playerY, playerZ = player:getPosition()
  end

  -- Find closest lights to the player for better performance
  local nearbyLights = {}
  for _, lightPost in ipairs(lightPosts) do
    local distance = math.sqrt((lightPost.x - playerX) ^ 2 + (lightPost.z - playerZ) ^ 2)
    if distance <= renderDistance then
      table.insert(nearbyLights, { light = lightPost, distance = distance })
    end
  end

  -- Sort by distance and take only the closest maxLights
  table.sort(nearbyLights, function(a, b) return a.distance < b.distance end)

  local lightsToSend = {}
  for i = 1, math.min(#nearbyLights, maxLights) do
    table.insert(lightsToSend, nearbyLights[i].light)
  end

  -- Send light data to shader
  local lightPositions = {}
  local lightColors = {}
  local lightIntensities = {}
  local lightRanges = {}

  for i, lightPost in ipairs(lightsToSend) do
    table.insert(lightPositions, { lightPost.x, lightPost.y, lightPost.z })
    table.insert(lightColors, lightPost.color)
    table.insert(lightIntensities, lightPost.intensity)
    table.insert(lightRanges, lightPost.range)
  end

  pass:send('numLights', #lightsToSend)
  if #lightsToSend > 0 then
    pass:send('lightPositions', lightPositions)
    pass:send('lightColors', lightColors)
    pass:send('lightIntensities', lightIntensities)
    pass:send('lightRanges', lightRanges)
  end

  -- Draw all objects with multiple light illumination
  render_scene(pass)

  -- Reset shader
  pass:setShader()

  -- Draw light posts (instead of single light sphere)
  render_light_posts(pass)

  -- Debug: Draw local player collider if debug is enabled
  if _G.showColliderDebug and player then
    local playerX, playerY, playerZ = player:getPosition()
    local angle, ax, ay, az = player:getOrientation()
    pass:setColor(0, 1, 0, 0.3) -- Semi-transparent green for local player
    -- Use Pass:box to draw the exact same shape as the physics collider
    -- Apply the same rotation as the physics collider
    pass:push()
    pass:translate(playerX, playerY, playerZ)
    pass:rotate(angle, ax, ay, az)                                           -- Apply angle-axis rotation
    pass:box(0, 0, 0, boxColliderWidth, boxColliderHeight, boxColliderDepth) -- Use actual box shape dimensions
    pass:pop()
    pass:setColor(1, 1, 1)                                                   -- Reset color
  end


  if (multiplayerMode == "host" or multiplayerMode == "client") and multiplayerClient then
    if multiplayerClient.players then
      local currentTime = lovr.timer.getTime()
      for playerId, playerData in pairs(multiplayerClient.players) do
        -- Use the same position calculation as the model rendering for consistency
        local renderPos = lovr.math.newVec3(playerData.position)

        -- Apply interpolation for network position
        if playerData.lastPosition then
          local timeSinceUpdate = currentTime - playerData.lastUpdate
          local alpha = math.min(timeSinceUpdate * 20, 1.0) -- Interpolation factor

          if alpha < 1.0 then
            -- Interpolate for smoother movement
            renderPos:set(playerData.lastPosition):lerp(playerData.position, alpha)
          end
        end

        -- Apply physics offset with time-based decay for collision effects (same as model)
        if playerData.physicsOffset and playerData.offsetTime then
          local timeSinceOffset = currentTime - playerData.offsetTime
          local decayDuration = 0.5 -- How long the offset lasts (0.5 seconds)

          if timeSinceOffset < decayDuration then
            -- Apply decaying offset for visual collision feedback
            local decayFactor = 1.0 - (timeSinceOffset / decayDuration)
            local scaledOffset = lovr.math.newVec3(playerData.physicsOffset):mul(decayFactor)
            renderPos:add(scaledOffset)
          end
        end

        -- Debug: Draw collider outline if the collider exists and debug is enabled
        if _G.showColliderDebug and playerData.collider then
          local colliderX, colliderY, colliderZ = playerData.collider:getPosition()
          local angle, ax, ay, az = playerData.collider:getOrientation()
          pass:setColor(1, 0, 0, 0.3) -- Semi-transparent red for multiplayer player colliders
          -- Use Pass:box to draw the exact same shape as the physics collider
          -- Apply the same rotation as the physics collider
          pass:push()
          pass:translate(colliderX, colliderY, colliderZ)
          pass:rotate(angle, ax, ay, az)                                           -- Apply angle-axis rotation
          pass:box(0, 0, 0, boxColliderWidth, boxColliderHeight, boxColliderDepth) -- Use actual box shape dimensions
          pass:pop()
          pass:setColor(1, 1, 1)                                                   -- Reset color
        end

        -- Draw player ID above player (rotates with player's camera yaw)
        pass:setColor(1, 1, 1)
        pass:push()
        pass:translate(renderPos.x, renderPos.y + 0.75, renderPos.z) -- Higher above player - using same position as model
        pass:rotate(playerData.yaw + math.pi, 0, 1, 0)               -- Rotate with player's camera yaw + 180 degrees to fix backwards text
        pass:text("P" .. playerId, 0, 0, 0, 0.2)                     -- Text directly above player, no forward offset
        pass:pop()
      end
    end
  end

  pass:setColor(1, 1, 1) -- Reset color to white
  pass:pop()

  -- Draw HUD overlay using proper technique
  drawPlayerListHUD(pass)

  -- Draw inventory at bottom of screen
  drawInventory(pass)

  -- Draw reticle at center of screen
  drawReticle(pass)

  -- No longer need shadow passes - just submit the main pass
  return lovr.graphics.submit(pass)
end

function drawMainMenu(pass)
  -- Draw semi-transparent overlay
  pass:setColor(0, 0, 0, 0.7) -- Dark overlay
  pass:plane(0, 0, -2, 8, 6)  -- Large plane in front

  -- Draw menu title
  pass:setColor(1, 1, 1)                                          -- White
  pass:text("LOVR MULTIPLAYER (ENet)", 0, 1.2, -2, 0.25)          -- Reduced from 0.4 to 0.25
  pass:setColor(0.6, 0.8, 1)                                      -- Light blue
  pass:text("Ultra-low latency UDP networking", 0, 0.9, -2, 0.15) -- Reduced from 0.2 to 0.15

  -- Draw menu options
  for i, option in ipairs(menuOptions) do
    local y = 0.6 - (i - 1) * 0.25                     -- Reduced spacing from 0.3 to 0.25
    if i == menuSelection then
      pass:setColor(1, 1, 0)                           -- Yellow for selected option
      pass:text("> " .. option .. " <", 0, y, -2, 0.2) -- Reduced from 0.3 to 0.2
    else
      pass:setColor(0.8, 0.8, 0.8)                     -- Gray for unselected options
      pass:text(option, 0, y, -2, 0.2)                 -- Reduced from 0.3 to 0.2
    end
  end

  -- Draw instructions
  pass:setColor(0.6, 0.6, 0.6)                                         -- Light gray
  pass:text("Use W/S to navigate, Space to select", 0, -1.0, -2, 0.15) -- Reduced from 0.2 to 0.15

  -- Show current server address
  pass:setColor(0.8, 1, 0.8)                                                              -- Light green
  pass:text("Current Server: " .. serverAddress .. ":" .. serverPort, 0, -1.25, -2, 0.12) -- Reduced from 0.15 to 0.12

  -- Show multiplayer status if applicable
  if multiplayerMode ~= "single" then
    pass:setColor(0.8, 0.8, 1) -- Light blue
    pass:text("Current mode: " .. multiplayerMode .. " (ENet)", 0, -1.45, -2, 0.12) -- Reduced from 0.15 to 0.12
    if multiplayerClient and multiplayerClient:isConnected() then
      pass:setColor(0.6, 1, 0.6) -- Light green
      pass:text("✓ Connected - Players: " .. (multiplayerClient:getPlayerCount() + 1), 0, -1.65, -2, 0.12) -- Reduced from 0.15 to 0.12
    end
  end
end

function drawIPInput(pass)
  -- Draw semi-transparent overlay
  pass:setColor(0, 0, 0, 0.8) -- Darker overlay
  pass:plane(0, 0, -2, 8, 6)  -- Large plane in front

  -- Draw title
  pass:setColor(1, 1, 1)                                 -- White
  pass:text("ENTER SERVER IP ADDRESS", 0, 1.3, -2, 0.25) -- Reduced from 0.4 to 0.25

  -- Draw current input with cursor
  local displayText = ipInputText
  local cursorTime = lovr.timer.getTime() * 2
  if math.floor(cursorTime) % 2 == 0 then
    displayText = ipInputText .. "|"
  end

  -- Input box background (dark blue box)
  pass:setColor(0.1, 0.1, 0.3, 0.9) -- Dark blue background
  pass:plane(0, 0.8, -1.98, 5, 0.5) -- Made box smaller: width 5 (from 6), height 0.5 (from 0.6)

  -- Input text - centered inside the box (in front of the box)
  pass:setColor(1, 1, 0)                     -- Yellow text for better visibility
  pass:text(displayText, 0, 0.8, -1.97, 0.2) -- Reduced from 0.3 to 0.2

  -- Show what's currently typed (for debugging) - moved below input box
  pass:setColor(0.8, 1, 0.8)                                                                                  -- Light green
  pass:text("Current: '" .. ipInputText .. "' (length: " .. string.len(ipInputText) .. ")", 0, 0.4, -2, 0.12) -- Reduced from 0.15 to 0.12

  -- Instructions - moved further down
  pass:setColor(0.8, 0.8, 0.8)                                                                  -- Gray
  pass:text("Type numbers, letters, and dots (e.g., 192.168.1.50)", 0, 0.1, -2, 0.15)           -- Reduced from 0.2 to 0.15
  pass:text("Press Enter to confirm, Escape to cancel, Backspace to delete", 0, -0.1, -2, 0.15) -- Reduced from 0.2 to 0.15

  -- Examples - moved further down
  pass:setColor(0.6, 0.8, 1)                                    -- Light blue
  pass:text("Examples:", 0, -0.4, -2, 0.15)                     -- Reduced from 0.18 to 0.15
  pass:text("localhost (same computer)", 0, -0.6, -2, 0.12)     -- Reduced from 0.15 to 0.12
  pass:text("192.168.1.100 (local network)", 0, -0.8, -2, 0.12) -- Reduced from 0.15 to 0.12
  pass:text("10.0.0.50 (local network)", 0, -1.0, -2, 0.12)     -- Reduced from 0.15 to 0.12
end

function drawSettingsMenu(pass)
  -- Draw semi-transparent overlay
  pass:setColor(0, 0, 0, 0.7) -- Dark overlay
  pass:plane(0, 0, -2, 8, 6)  -- Large plane in front

  -- Draw menu title
  pass:setColor(1, 1, 1) -- White
  pass:text("GAME SETTINGS", 0, 1.2, -2, 0.3)

  -- Draw settings options
  for i, option in ipairs(settingsOptions) do
    local y = 0.6 - (i - 1) * 0.4
    if i == settingsSelection then
      pass:setColor(1, 1, 0) -- Yellow for selected option
      if option == "Render Distance" then
        pass:text("> " .. option .. " <", 0, y, -2, 0.2)

        -- Draw render distance slider
        local sliderY = y - 0.25
        local sliderWidth = 3.0
        local sliderHeight = 0.1

        -- Slider background (dark)
        pass:setColor(0.3, 0.3, 0.3)
        pass:plane(0, sliderY, -1.99, sliderWidth, sliderHeight)

        -- Slider track (lighter)
        pass:setColor(0.5, 0.5, 0.5)
        pass:plane(0, sliderY, -1.98, sliderWidth * 0.95, sliderHeight * 0.6)

        -- Calculate slider position based on render distance
        local sliderPos = (renderDistance - minRenderDistance) / (maxRenderDistance - minRenderDistance)
        sliderPos = math.max(0, math.min(1, sliderPos))         -- Clamp between 0 and 1
        local sliderX = (sliderPos - 0.5) * (sliderWidth * 0.9) -- Position on slider

        -- Slider handle (always active when render distance is selected)
        if i == settingsSelection then
          pass:setColor(1, 1, 0)     -- Yellow when selected
        else
          pass:setColor(0.8, 0.8, 1) -- Light blue when not selected
        end
        pass:sphere(sliderX, sliderY, -1.97, 0.05)

        -- Display current value
        pass:setColor(0.8, 1, 0.8) -- Light green
        pass:text(string.format("%.0f units", renderDistance), 0, sliderY - 0.2, -2, 0.15)

        -- Display min/max labels
        pass:setColor(0.6, 0.6, 0.6) -- Gray
        pass:text(tostring(minRenderDistance), -sliderWidth / 2, sliderY + 0.15, -2, 0.12)
        pass:text(tostring(maxRenderDistance), sliderWidth / 2, sliderY + 0.15, -2, 0.12)
      else
        pass:text("> " .. option .. " <", 0, y, -2, 0.2)
      end
    else
      pass:setColor(0.8, 0.8, 0.8) -- Gray for unselected options
      pass:text(option, 0, y, -2, 0.2)
    end
  end

  -- Draw instructions
  pass:setColor(0.6, 0.6, 0.6) -- Light gray
  pass:text("Use W/S to navigate, A/D to adjust values, Space to select", 0, -1.0, -2, 0.15)
  pass:text("Press Escape to go back", 0, -1.2, -2, 0.15)
end

-- Text input handler for IP address
function lovr.textinput(text)
  if gameState == "ip_input" then
    -- Add typed character to IP input
    ipInputText = ipInputText .. text
    ipInputCursor = ipInputCursor + 1
    print("lovr.textinput: Added '" .. text .. "', full text now: '" .. ipInputText .. "'")
  end
end

function startHostGame()
  multiplayerMode = "host"
  print("DEBUG: Set multiplayer mode to HOST")

  -- Start ENet server
  multiplayerServer = MultiplayerENetServer.new(serverPort)
  if multiplayerServer:start() then
    print("ENet server started successfully")

    -- Connect as client to own server
    multiplayerClient = MultiplayerENetClient.new("localhost", serverPort)
    if multiplayerClient:connect() then
      print("Connected to own ENet server")
    else
      print("Failed to connect to own server")
      multiplayerServer:stop()
      multiplayerServer = nil
      multiplayerMode = "single"
    end
  else
    print("Failed to start ENet server")
    multiplayerMode = "single"
  end
end

function startClientGame()
  multiplayerMode = "client"
  print("DEBUG: Set multiplayer mode to CLIENT")

  -- Connect to remote ENet server
  multiplayerClient = MultiplayerENetClient.new(serverAddress, serverPort)
  if multiplayerClient:connect() then
    print("Connecting to ENet server at " .. serverAddress .. ":" .. serverPort)
  else
    print("Failed to create connection to ENet server")
    multiplayerMode = "single"
  end
end

function stopMultiplayer()
  if multiplayerClient then
    multiplayerClient:disconnect()
    multiplayerClient = nil
  end

  if multiplayerServer then
    multiplayerServer:stop()
    multiplayerServer = nil
  end

  multiplayerMode = "single"
  print("Returned to single player mode")
end

function lovr.mousemoved(x, y, dx, dy)
  camera.pitch = math.max(-math.pi / 2, math.min(math.pi / 2, camera.pitch - dy * 0.004))
  camera.yaw = camera.yaw - dx * 0.004
end

function lovr.wheelmoved(dx, dy)
  if gameState == "playing" then
    -- Scroll through inventory slots
    if dy > 0 then
      -- Scroll up - move to previous slot
      selectedSlot = selectedSlot - 1
      if selectedSlot < 1 then
        selectedSlot = 8 -- Wrap around to slot 8
      end
    elseif dy < 0 then
      -- Scroll down - move to next slot
      selectedSlot = selectedSlot + 1
      if selectedSlot > 8 then
        selectedSlot = 1 -- Wrap around to slot 1
      end
    end
  end
end

function lovr.keypressed(key)
  if key == 'escape' then
    if gameState == "playing" then
      gameState = "menu"
      lovr.mouse.setRelativeMode(false) -- Show cursor in menu
    elseif gameState == "menu" then
      gameState = "playing"
      lovr.mouse.setRelativeMode(true) -- Hide cursor when playing
    elseif gameState == "settings" then
      gameState = "menu"
    elseif gameState == "ip_input" then
      gameState = "menu"
      ipInputText = serverAddress -- Revert changes
    end
  end

  if gameState == "menu" then
    -- Menu navigation
    if key == 'w' or key == 'up' then
      menuSelection = menuSelection - 1
      if menuSelection < 1 then
        menuSelection = #menuOptions
      end
    elseif key == 's' or key == 'down' then
      menuSelection = menuSelection + 1
      if menuSelection > #menuOptions then
        menuSelection = 1
      end
    elseif key == 'space' or key == 'return' then
      -- Execute selected menu option
      if menuOptions[menuSelection] == "Resume" then
        gameState = "playing"
        lovr.mouse.setRelativeMode(true)
      elseif menuOptions[menuSelection] == "Host Game" then
        startHostGame()
        gameState = "playing"
        lovr.mouse.setRelativeMode(true)
      elseif menuOptions[menuSelection] == "Join Game" then
        startClientGame()
        gameState = "playing"
        lovr.mouse.setRelativeMode(true)
      elseif menuOptions[menuSelection] == "Change Server IP" then
        gameState = "ip_input"
      elseif menuOptions[menuSelection] == "Settings" then
        gameState = "settings"
        settingsSelection = 1
      elseif menuOptions[menuSelection] == "Quit" then
        stopMultiplayer()
        lovr.event.quit()
      end
    end
  elseif gameState == "playing" then
    -- Game controls
    if key == 'space' then
      -- Jump - only if on ground (playerOnGround is true)
      if playerOnGround then
        player:applyLinearImpulse(0, playerJumpForce, 0)
      end
    elseif key == 'h' then
      -- Quick host game
      if multiplayerMode == "single" then
        startHostGame()
      else
        stopMultiplayer()
      end
    elseif key == 'j' then
      -- Quick join game
      if multiplayerMode == "single" then
        startClientGame()
      else
        stopMultiplayer()
      end
    elseif key == 'p' then
      -- Show current ping information
      if multiplayerMode == "host" and multiplayerServer then
        pingText = "PING STATUS (HOST):\n"
        local clientCount = 0
        for playerId, pingValue in pairs(multiplayerServer.clientPings) do
          clientCount = clientCount + 1
          pingText = pingText .. "Player " .. playerId .. ": " .. string.format("%.0f", pingValue) .. "ms\n"
        end
        if clientCount == 0 then
          pingText = pingText .. "No clients connected"
        end
      elseif multiplayerMode == "client" and multiplayerClient then
        pingText = "PING STATUS (CLIENT):\n"
        if multiplayerClient:isConnected() then
          local serverPingText = "Server: "
          if multiplayerClient.ping > 0 then
            serverPingText = serverPingText .. string.format("%.0f", multiplayerClient.ping) .. "ms"
            if multiplayerClient.lastPingTime > 0 then
              local timeSinceLastPing = lovr.timer.getTime() - multiplayerClient.lastPingTime
              serverPingText = serverPingText .. "\n(updated " .. string.format("%.1f", timeSinceLastPing) .. "s ago)"
            end
          else
            serverPingText = serverPingText .. "Unknown\n(no ping data yet)"
          end
          pingText = pingText .. serverPingText
          -- Send a ping to get fresh data
          multiplayerClient:pingServer()
        else
          pingText = pingText .. "Not connected to server"
        end
      else
        pingText = "PING STATUS (SINGLE PLAYER):\nNo network connection"
      end
      -- Set display timer when ping is shown
      pingDisplayTime = lovr.timer.getTime()
    elseif key == 'o' then
      -- Clear ping display
      pingText = ""
      pingDisplayTime = 0
    elseif key == 'i' then
      -- Add test items to inventory for demonstration
      inventory[1] = { item = "Rock", count = 5, icon = nil }
      inventory[2] = { item = "Wood", count = 12, icon = nil }
      inventory[3] = { item = "Metal", count = 3, icon = nil }
      inventory[5] = { item = "Tool", count = 1, icon = nil }
      print("Added test items to inventory")
    elseif key == 'up' then
      -- Increase light intensity
      light_intensity = light_intensity + 0.2
      print("Light intensity: " .. light_intensity)
    elseif key == 'down' then
      -- Decrease light intensity
      light_intensity = math.max(0.1, light_intensity - 0.2)
      print("Light intensity: " .. light_intensity)
    elseif key == 'c' then
      -- Toggle collider debug visualization
      if not _G.showColliderDebug then
        _G.showColliderDebug = true
        print("Collider debug visualization: ON")
      else
        _G.showColliderDebug = false
        print("Collider debug visualization: OFF")
      end
    elseif key >= '1' and key <= '8' then
      -- Select inventory slot by number key
      local slotNumber = tonumber(key)
      if slotNumber then
        selectedSlot = slotNumber
        print("Selected inventory slot " .. slotNumber)
      end
    elseif key == 'r' then
      -- Reset/respawn player at safe spawn height
      local spawnHeight = getSafeSpawnHeight(0, 0)
      player:setPosition(0, spawnHeight, 0)
      player:setLinearVelocity(0, 0, 0)
      player:setAngularVelocity(0, 0, 0)
      camera.position:set(0, spawnHeight + cameraHeightOffset, 0)
      print("Respawned player at safe spawn height: " .. spawnHeight .. " (1m above terrain)")
    elseif key == 't' then
      -- Test terrain physics vs graphics alignment at current player position
      local px, py, pz = player:getPosition()
      print("Testing terrain physics/graphics alignment at player position...")
      debugTerrainPhysicsAlignment(px, pz)

      -- Also test a few nearby points to verify consistency
      print("Testing nearby points for alignment verification...")
      for i = -1, 1 do
        for j = -1, 1 do
          if i ~= 0 or j ~= 0 then    -- Skip the center point (already tested)
            local testX = px + i * 10 -- Test points 10 units apart
            local testZ = pz + j * 10
            local physicsHeight = debugTerrainPhysicsAlignment(testX, testZ)
          end
        end
      end
    elseif key == 'y' then
      -- Show terrain tile system information
      print("=== TERRAIN TILE SYSTEM DEBUG ===")
      local px, py, pz = player:getPosition()
      local playerTileX, playerTileZ = worldToTileCoords(px, pz)

      print("Player position: (" .. string.format("%.2f", px) .. ", " .. string.format("%.2f", pz) .. ")")
      print("Player tile: (" .. playerTileX .. ", " .. playerTileZ .. ")")
      print("Active tiles: " .. #activeTiles)
      print("Loaded tiles:")

      local tileList = {}
      for tileKey, tile in pairs(terrainTiles) do
        table.insert(tileList, {
          key = tileKey,
          x = tile.tileX,
          z = tile.tileZ,
          distance = math.sqrt((tile.tileX - playerTileX) ^ 2 + (tile.tileZ - playerTileZ) ^ 2)
        })
      end

      -- Sort by distance from player
      table.sort(tileList, function(a, b) return a.distance < b.distance end)

      for i, tile in ipairs(tileList) do
        if i <= 10 then -- Show first 10 tiles
          print("  Tile (" .. tile.x .. ", " .. tile.z .. ") - Distance: " .. string.format("%.1f", tile.distance))
        end
      end

      if #tileList > 10 then
        print("  ... and " .. (#tileList - 10) .. " more tiles")
      end

      -- Force a tile update
      print("Forcing terrain tile update...")
      lastPlayerTileX = nil -- Force update
      lastPlayerTileZ = nil
      updateTerrainTiles()
    elseif key == 'f' then
      -- Debug player footing (what's under the player's feet)
      debugPlayerFooting()
    elseif key == 'u' then
      -- Direct raycast vs physics comparison at player position
      print("=== DIRECT TERRAIN RAYCAST vs PHYSICS TEST ===")
      local px, py, pz = player:getPosition()

      -- Test 1: Direct raycast down from player position
      print("1. RAYCAST TEST from player position:")
      local raycastHeight = nil
      world:raycast(px, py + 50, pz, px, py - 50, pz, nil, function(shape, x, y, z, nx, ny, nz)
        if shape and shape.getCollider then
          local collider = shape:getCollider()
          local userData = collider:getUserData()
          if userData and userData.type == "terrain" then
            raycastHeight = tonumber(y) or 0
            print("  Raycast hit terrain at Y = " .. string.format("%.3f", raycastHeight))
            return false
          end
        end
      end)

      if not raycastHeight then
        print("  Raycast found no terrain!")
      end

      -- Test 2: Check what our height function returns
      local expectedHeight = terrainHeightFunction(px, pz)
      print("2. HEIGHT FUNCTION returns: " .. string.format("%.3f", expectedHeight))

      -- Test 3: Compare
      if raycastHeight then
        local difference = math.abs(raycastHeight - expectedHeight)
        print("3. COMPARISON:")
        print("  Raycast height: " .. string.format("%.3f", raycastHeight))
        print("  Expected height: " .. string.format("%.3f", expectedHeight))
        print("  Difference: " .. string.format("%.3f", difference))

        if difference < 0.1 then
          print("  ✓ GOOD: Raycast matches height function!")
        else
          print("  ✗ BAD: Significant difference detected!")
        end
      end
    end
  elseif gameState == "ip_input" then
    -- IP Input system - only handle special keys here
    if key == 'backspace' then
      if string.len(ipInputText) > 0 then
        ipInputText = string.sub(ipInputText, 1, -2)
        ipInputCursor = math.max(0, ipInputCursor - 1)
        print("Backspace pressed, text now: '" .. ipInputText .. "'")
      end
    elseif key == 'return' then
      serverAddress = ipInputText
      print("Server address changed to: " .. serverAddress)
      gameState = "menu"
    elseif key == 'escape' then
      -- Cancel IP input, revert to original
      ipInputText = serverAddress
      gameState = "menu"
    end
    -- Note: Character input is handled by lovr.textinput, not here
  elseif gameState == "settings" then
    -- Settings menu navigation
    if key == 'w' or key == 'up' then
      settingsSelection = settingsSelection - 1
      if settingsSelection < 1 then
        settingsSelection = #settingsOptions
      end
    elseif key == 's' or key == 'down' then
      settingsSelection = settingsSelection + 1
      if settingsSelection > #settingsOptions then
        settingsSelection = 1
      end
    elseif key == 'space' or key == 'return' then
      -- Execute selected settings option
      if settingsOptions[settingsSelection] == "Back to Main Menu" then
        gameState = "menu"
      end
    elseif key == 'a' or key == 'left' then
      -- Decrease render distance when on render distance option
      if settingsOptions[settingsSelection] == "Render Distance" then
        renderDistance = math.max(minRenderDistance, renderDistance - 25)
        print("Render distance decreased to: " .. renderDistance)
      end
    elseif key == 'd' or key == 'right' then
      -- Increase render distance when on render distance option
      if settingsOptions[settingsSelection] == "Render Distance" then
        renderDistance = math.min(maxRenderDistance, renderDistance + 25)
        print("Render distance increased to: " .. renderDistance)
      end
    elseif key == 'escape' then
      -- Go back to main menu
      gameState = "menu"
    end
  end
end

-- Compass drawing function
function drawCompass(pass)
  local compassDistance = -0.6 -- Slightly further than other HUD elements
  local compassY = 0.35        -- Top of screen
  local compassSize = 0.15     -- Compass radius

  -- Save current state before modifying
  pass:push()
  -- Move to compass position (top center)
  pass:translate(0, compassY, compassDistance)

  -- No background sphere/cylinder - just text and needle

  -- Calculate direction based on camera yaw (North is 0, increases clockwise)
  local northAngle = -camera.yaw -- Negate because camera yaw increases counter-clockwise

  -- Draw degree markings around the compass (every 45 degrees for clarity)
  for i = 0, 315, 45 do
    local angle = math.rad(i) + northAngle
    local x = math.sin(angle) * (compassSize * 0.8)
    local z = math.cos(angle) * (compassSize * 0.8)

    -- Different colors for major directions
    if i == 0 then
      pass:setColor(1, 0.3, 0.3)   -- North - Red
    elseif i == 90 or i == 180 or i == 270 then
      pass:setColor(1, 1, 1)       -- Cardinal directions - White
    else
      pass:setColor(0.9, 0.9, 0.9) -- Other degrees - Light gray
    end

    -- Position text above the compass surface
    pass:text(tostring(i) .. "°", x, 0.03, z, 0.025)
  end

  -- Draw cardinal direction markers (larger and more prominent)
  local directions = {
    { name = "N", angle = 0,            color = { 1, 0.2, 0.2 } }, -- North - Red
    { name = "E", angle = math.pi / 2,  color = { 1, 1, 1 } },     -- East - White
    { name = "S", angle = math.pi,      color = { 1, 1, 1 } },     -- South - White
    { name = "W", angle = -math.pi / 2, color = { 1, 1, 1 } }      -- West - White
  }

  for _, dir in ipairs(directions) do
    local angle = dir.angle + northAngle
    local x = math.sin(angle) * (compassSize * 0.6)
    local z = math.cos(angle) * (compassSize * 0.6)

    pass:setColor(dir.color[1], dir.color[2], dir.color[3])
    pass:text(dir.name, x, 0.04, z, 0.05) -- Above degree numbers and larger
  end

  -- Draw current heading in center
  local currentHeading = math.floor((-camera.yaw * 180 / math.pi) % 360)
  if currentHeading < 0 then currentHeading = currentHeading + 360 end
  pass:setColor(1, 1, 0) -- Yellow
  pass:text(tostring(currentHeading) .. "°", 0, 0.05, 0, 0.04)

  -- Draw compass needle pointing forward (camera direction)
  pass:setColor(1, 1, 0) -- Yellow needle
  pass:box(0, 0.01, -compassSize * 0.5, 0.005, 0.02, compassSize * 0.3)

  -- Draw center dot
  pass:setColor(1, 0, 0) -- Red center
  pass:sphere(0, 0.015, 0, 0.008)

  -- Restore previous state
  pass:pop()
end

-- Reticle drawing function
function drawReticle(pass)
  if gameState ~= "playing" then return end

  -- Get camera position and orientation for HUD positioning
  local cx, cy, cz = camera.position.x, camera.position.y, camera.position.z
  local cameraYaw = camera.yaw
  local cameraPitch = camera.pitch

  pass:push()
  pass:origin()
  pass:translate(cx, cy, cz)
  pass:rotate(cameraYaw, 0, 1, 0)
  pass:rotate(cameraPitch, 1, 0, 0)
  pass:translate(0, 0, -0.5) -- Center of screen

  -- Reticle configuration
  local reticleSize = 0.01       -- Size of the crosshair lines
  local reticleGap = 0.005       -- Gap in the center
  local reticleThickness = 0.002 -- Thickness of the lines

  -- Set reticle color (white with slight transparency)
  pass:setColor(1, 1, 1, 0.8)

  -- Draw horizontal lines (left and right of center)
  pass:box(-reticleGap - reticleSize / 2, 0, 0, reticleSize, reticleThickness, reticleThickness) -- Left line
  pass:box(reticleGap + reticleSize / 2, 0, 0, reticleSize, reticleThickness, reticleThickness)  -- Right line

  -- Draw vertical lines (top and bottom of center)
  pass:box(0, reticleGap + reticleSize / 2, 0, reticleThickness, reticleSize, reticleThickness)  -- Top line
  pass:box(0, -reticleGap - reticleSize / 2, 0, reticleThickness, reticleSize, reticleThickness) -- Bottom line

  -- Optional: Draw center dot
  pass:setColor(1, 1, 1, 0.6)
  pass:sphere(0, 0, 0, 0.001)

  pass:pop()
end

-- Inventory drawing function
function drawInventory(pass)
  if gameState ~= "playing" then return end

  -- Get camera position and orientation for HUD positioning
  local cx, cy, cz = camera.position.x, camera.position.y, camera.position.z
  local cameraYaw = camera.yaw
  local cameraPitch = camera.pitch

  pass:push()
  pass:origin()
  pass:translate(cx, cy, cz)
  pass:rotate(cameraYaw, 0, 1, 0)
  pass:rotate(cameraPitch, 1, 0, 0)
  pass:translate(0, -0.25, -0.5) -- Bottom center of screen (moved up)

  -- Inventory configuration
  local slotSize = 0.06
  local slotSpacing = 0.07
  local totalWidth = (8 * slotSpacing) - (slotSpacing - slotSize)
  local startX = -totalWidth / 2

  -- No background panel - just individual slots

  -- Draw individual inventory slots
  for i = 1, 8 do
    local slotX = startX + (i - 1) * slotSpacing
    local slotY = 0

    -- Draw slot border first
    if i == selectedSlot then
      pass:setColor(1, 1, 0, 1) -- Bright yellow border for selected slot
      pass:plane(slotX, slotY, 0.001, slotSize + 0.01, slotSize + 0.01)
    else
      pass:setColor(1, 1, 1, 1) -- White border for unselected slots
      pass:plane(slotX, slotY, 0.001, slotSize + 0.005, slotSize + 0.005)
    end

    -- Draw slot background on top of border
    if i == selectedSlot then
      pass:setColor(1, 1, 0, 0.3)       -- Semi-transparent yellow for selected slot
    else
      pass:setColor(0.3, 0.3, 0.3, 0.9) -- Dark gray for unselected slots
    end
    pass:plane(slotX, slotY, 0.002, slotSize, slotSize)

    -- Draw slot number
    pass:setColor(1, 1, 1) -- White text
    pass:text(tostring(i), slotX, slotY + slotSize / 2 - 0.01, 0.003, 0.015)

    -- Draw item if present
    if inventory[i].item then
      -- For now, just draw item name (later we can add icons)
      pass:setColor(0.8, 1, 0.8) -- Light green for items
      pass:text(inventory[i].item, slotX, slotY - 0.01, 0.003, 0.012)

      -- Draw item count if > 1
      if inventory[i].count > 1 then
        pass:setColor(1, 1, 1) -- White for count
        pass:text(tostring(inventory[i].count), slotX + slotSize / 3, slotY - slotSize / 3, 0.003, 0.01)
      end
    end
  end

  pass:pop()
end

-- Simplified HUD drawing function with solid backgrounds and larger text
function drawPlayerListHUD(pass)
  -- Calculate player count first
  local playerCount = 1 -- Self
  if multiplayerClient then
    playerCount = playerCount + multiplayerClient:getPlayerCount()
  end

  -- Always show compass, but only show player list in multiplayer
  local showPlayerList = not (multiplayerMode == "single" and playerCount == 1)
  -- Get camera position and orientation for HUD positioning
  local cx, cy, cz = camera.position.x, camera.position.y, camera.position.z
  local cameraYaw = camera.yaw
  local cameraPitch = camera.pitch
  pass:push()
  pass:origin()
  pass:translate(cx, cy, cz)
  pass:rotate(cameraYaw, 0, 1, 0)
  pass:rotate(cameraPitch, 1, 0, 0)
  pass:translate(0.3, 0.3, -0.5)
  pass:setColor(1, 1, 1) -- White text
  pass:text("FPS: " .. math.floor(lovr.timer.getFPS()), 0, 0, 0, 0.05)
  pass:pop()

  -- Ping display (positioned near FPS)
  if pingText and pingText ~= "" then
    pass:push()
    pass:origin()
    pass:translate(cx, cy, cz)
    pass:rotate(cameraYaw, 0, 1, 0)
    pass:rotate(cameraPitch, 1, 0, 0)
    pass:translate(0.3, 0.2, -0.5) -- Slightly below FPS

    -- Count lines in pingText to adjust background size
    local lineCount = 1
    for _ in pingText:gmatch("\n") do
      lineCount = lineCount + 1
    end

    -- Ping background (adjust height based on line count)
    local bgHeight = 0.04 + (lineCount * 0.025)
    local bgWidth = 0.3
    pass:setColor(0, 0, 0, 0.9) -- Black background
    pass:plane(0, 0, 0, bgWidth, bgHeight)

    -- White border for ping display
    pass:setColor(1, 1, 1, 1) -- White border
    pass:plane(0, 0, -0.001, bgWidth + 0.01, bgHeight + 0.01)
    -- Re-draw the black background on top
    pass:setColor(0, 0, 0, 0.9)
    pass:plane(0, 0, 0, bgWidth, bgHeight)

    -- Ping text
    pass:setColor(0, 1, 1) -- Bright cyan for ping text
    pass:text(pingText, 0, 0, 0.01, 0.025)
    pass:pop()
  end
  -- Save current transform state
  pass:push()
  -- Reset to world origin, then position relative to camera
  pass:origin()
  pass:translate(cx, cy, cz)
  pass:rotate(cameraYaw, 0, 1, 0)
  pass:rotate(cameraPitch, 1, 0, 0)

  -- Draw compass at top center of HUD
  drawCompass(pass)

  -- Position HUD very close to camera for clarity
  local hudDistance = -0.5 -- Very close to camera
  local hudX = 0.45        -- Right side
  local hudY = 0.1         -- Lower than before to make room for compass

  if showPlayerList then
    -- Player list panel - make it bigger and more visible
    local panelWidth = 0.4  -- Much smaller panel
    local lineHeight = 0.08 -- Larger line spacing
    local panelHeight = 0.2 + (playerCount * lineHeight)

    -- Move to HUD position
    pass:translate(hudX, hudY, hudDistance)

    -- Solid black background for maximum contrast
    pass:setColor(0, 0, 0, 0.9) -- Nearly opaque black background
    pass:plane(0, 0, 0, panelWidth, panelHeight)

    -- White border effect using slightly larger background plane
    pass:setColor(1, 1, 1, 1) -- White border
    pass:plane(0, 0, -0.001, panelWidth + 0.02, panelHeight + 0.02)
    -- Re-draw the black background on top
    pass:setColor(0, 0, 0, 0.9)
    pass:plane(0, 0, 0, panelWidth, panelHeight)

    -- Title - much larger and more visible
    pass:setColor(1, 1, 0)                                      -- Bright yellow for high contrast
    pass:text("PLAYERS", 0, panelHeight / 2 - 0.05, 0.01, 0.06) -- Much larger title

    local yPos = panelHeight / 2 - 0.12

    -- Show self first
    pass:setColor(0.5, 1, 1) -- Bright cyan for self
    local selfText = "You"
    if multiplayerClient and multiplayerClient.playerId then
      selfText = selfText .. " (ID: " .. multiplayerClient.playerId .. ")"
    end
    if multiplayerMode == "host" then
      selfText = selfText .. " [HOST]"
    end
    pass:text(selfText, 0.03, yPos, 0.01, 0.04) -- Much larger text
    yPos = yPos - lineHeight

    -- Show other players
    if multiplayerClient then
      local px, py, pz = player:getPosition() -- Get player position for distance calculation
      for playerId, playerData in pairs(multiplayerClient.players) do
        pass:setColor(0.5, 1, 0.5)            -- Bright green for others
        local playerText = "Player " .. playerId

        -- Show distance from self
        local distance = math.sqrt(
          (playerData.position.x - px) ^ 2 +
          (playerData.position.y - py) ^ 2 +
          (playerData.position.z - pz) ^ 2
        )
        playerText = playerText .. string.format(" (%.1fm)", distance)

        pass:text(playerText, 0.03, yPos, 0.01, 0.04) -- Much larger text
        yPos = yPos - lineHeight
      end
    end

    -- Connection status at bottom
    if multiplayerMode ~= "single" then
      if multiplayerClient and multiplayerClient:isConnected() then
        pass:setColor(0.5, 1, 0.5) -- Bright green
        pass:text("✓ CONNECTED", 0.05, yPos, 0.01, 0.03) -- Larger status text
      else
        pass:setColor(1, 0.5, 0.5) -- Bright red
        pass:text("✗ DISCONNECTED", 0.03, yPos, 0.01, 0.03) -- Larger status text
      end
    end
  end -- End of showPlayerList if block

  -- Debug info (position it separately - top left of view)
  pass:origin()
  pass:translate(cx, cy, cz)
  pass:rotate(cameraYaw, 0, 1, 0)
  pass:rotate(cameraPitch, 1, 0, 0)
  pass:translate(-0.3, 0.3, hudDistance) -- Top left position

  -- Debug background
  pass:setColor(0, 0, 0, 0.9)                                -- Black background
  pass:plane(0, 0, 0, 0.35, 0.15)                            -- Smaller width: 0.35 instead of 0.6

  pass:setColor(1, 1, 0)                                     -- Bright yellow debug text
  pass:text("State: " .. gameState, 0.02, 0.03, 0.01, 0.015) -- Moved all text down by 0.02 units
  pass:text("Mode: " .. multiplayerMode, 0.02, 0.015, 0.01, 0.015)
  pass:text("Players: " .. playerCount, 0.02, 0, 0.01, 0.015)

  -- Show terrain info
  pass:text("Terrain: Infinite Tiles (" .. tileSize .. "x" .. tileSize .. " each, " .. #activeTiles .. " loaded)", 0.02,
    -0.015, 0.01, 0.015)

  -- Show house collider count
  local houseColliderCount = 0
  if houses then
    for _, house in ipairs(houses) do
      if house.hasCollider then
        houseColliderCount = houseColliderCount + 1
      end
    end
  end
  pass:text("House Colliders: " .. houseColliderCount, 0.02, -0.03, 0.01, 0.015)

  -- Show rock collider count
  local rockColliderCount = 0
  if rocks then
    for _, rock in ipairs(rocks) do
      if rock.hasCollider then
        rockColliderCount = rockColliderCount + 1
      end
    end
  end
  pass:text("Rock Colliders: " .. rockColliderCount, 0.02, -0.045, 0.01, 0.015)

  -- Show lights rendered count
  pass:text("Lights Rendered: " .. globalLightsRendered .. "/" .. #lightPosts, 0.02, -0.06, 0.01, 0.015)

  pass:text("Player Position Locked: " .. tostring(playerPositionLocked), 0.02, -0.075, 0.01, 0.015)

  pass:text("Player On Ground: " .. tostring(playerOnGround), 0.02, -0.09, 0.01, 0.015)
  pass:text("Ground Distance: " .. string.format("%.2f", groundDebug.distance), 0.02, -0.105, 0.01, 0.015)
  pass:text("Ground Hits: " .. groundDebug.hits .. " | Slope: " .. string.format("%.2f", groundDebug.slope), 0.02, -0.12,
    0.01, 0.015)
  local px, py, pz = player:getPosition()
  pass:text("Player Position: " .. string.format("%.2f, %.2f, %.2f", px, py, pz), 0.02, -0.135, 0.01, 0.015)
  pass:text("Terrain Height: " .. string.format("%.2f", groundDebug.terrainHeight or 0), 0.02, -0.15, 0.01, 0.015)

  -- Show terrain-based debug info
  if groundDebug.allHits and #groundDebug.allHits > 0 then
    local firstHit = groundDebug.allHits[1]
    pass:text("Detection Method: " .. (firstHit.hitShapeType or "unknown"), 0.02, -0.165, 0.01, 0.015)
    pass:text("Distance Calc: " .. (firstHit.debugComparison or "N/A"), 0.02, -0.18, 0.01, 0.015)
    pass:text(
      "Player Y: " ..
      string.format("%.2f", groundDebug.playerHeight or 0) ..
      " | Terrain Y: " .. string.format("%.2f", groundDebug.terrainHeight or 0), 0.02, -0.195, 0.01, 0.015)
    pass:text("Ground Valid: " .. tostring(firstHit.isBelow or false) .. " | Method: Direct Terrain Query", 0.02, -0.21,
      0.01, 0.015)

    -- Show final distance calculation
    pass:text("Final Distance: " .. string.format("%.2f", groundDebug.distance or 999), 0.02, -0.225, 0.01, 0.015)
    pass:text("Emergency Respawn: " .. tostring(groundDebug.emergencyRespawn), 0.02, -0.24, 0.01, 0.015)
  end



  -- Restore transform state
  pass:pop()
end

-- NPC Update Function - Call this from lovr.update()
function updateNPCs(dt)
  if not npcs then return end

  for i, npc in ipairs(npcs) do
    local pos = lovr.math.newVec3(npc.body:getPosition())

    -- Check if NPC is stuck (hasn't moved much)
    local distanceMoved = pos:distance(npc.lastPosition)
    if distanceMoved < 0.01 then -- Much more lenient - only consider stuck if barely moving at all
      npc.stuckTimer = npc.stuckTimer + dt
    else
      npc.stuckTimer = 0
    end
    npc.lastPosition:set(pos)

    -- Reset forces
    npc.avoidanceForce:set(0, 0, 0)
    npc.separationForce:set(0, 0, 0)
    npc.desiredVelocity:set(0, 0, 0)

    -- 1. OBSTACLE AVOIDANCE using raycast
    local avoidanceDistance = npcConfig.avoidanceRadius
    local currentVel = lovr.math.newVec3(npc.body:getLinearVelocity())

    -- Cast multiple rays in different directions
    local rayDirections = {
      { 0,    0, -1 },   -- Forward
      { -0.7, 0, -0.7 }, -- Forward-left
      { 0.7,  0, -0.7 }, -- Forward-right
      { -1,   0, 0 },    -- Left
      { 1,    0, 0 }     -- Right
    }

    local avoidanceFound = false
    for _, dir in ipairs(rayDirections) do
      local rayStart = lovr.math.newVec3(pos.x, pos.y, pos.z)
      local rayEnd = lovr.math.newVec3(
        pos.x + dir[1] * avoidanceDistance,
        pos.y,
        pos.z + dir[3] * avoidanceDistance
      )

      -- Raycast to detect obstacles
      world:raycast(rayStart.x, rayStart.y, rayStart.z, rayEnd.x, rayEnd.y, rayEnd.z, nil,
        function(shape, x, y, z, nx, ny, nz)
          -- Check if we have a valid shape and can get its collider
          if shape and shape.getCollider then
            local collider = shape:getCollider()
            -- Check if we hit a house (not terrain tiles or other NPCs)
            local isTerrainTile = false
            local isValidObstacle = false

            if collider then
              -- Check if this is the terrain collider
              local userData = collider:getUserData()
              if userData and userData.type == "terrain" then
                isTerrainTile = true
              end

              -- Check if this is a house or rock collider (valid obstacles)
              if not isTerrainTile and collider ~= npc.body then
                -- Check if it's a house collider
                for _, house in ipairs(houses) do
                  if house.collider == collider then
                    isValidObstacle = true
                    break
                  end
                end

                -- Check if it's a rock collider
                if not isValidObstacle then
                  for _, rock in ipairs(rocks) do
                    if rock.collider == collider then
                      isValidObstacle = true
                      break
                    end
                  end
                end
              end
            end

            if isValidObstacle then
              -- Calculate avoidance force perpendicular to hit normal
              local hitPoint = lovr.math.newVec3(x, y, z)
              local distToHit = rayStart:distance(hitPoint)
              local avoidStrength = (avoidanceDistance - distToHit) / avoidanceDistance

              -- Steer away from obstacle
              npc.avoidanceForce.x = npc.avoidanceForce.x + nx * avoidStrength * npcConfig.steerStrength
              npc.avoidanceForce.z = npc.avoidanceForce.z + nz * avoidStrength * npcConfig.steerStrength
              avoidanceFound = true
            end
          end
        end)
    end

    -- 2. SEPARATION from other NPCs - REMOVED to allow freer movement

    -- 3. WANDERING BEHAVIOR
    npc.wanderChangeTimer = npc.wanderChangeTimer + dt
    if npc.wanderChangeTimer > 30.0 or npc.stuckTimer > 1.0 then -- Change direction every 30 seconds or if stuck for 1 second
      npc.wanderChangeTimer = 0
      npc.stuckTimer = 0

      -- Choose new random direction
      npc.wanderAngle = lovr.math.random() * math.pi * 2

      -- Sometimes return towards spawn point if too far away
      local distanceFromSpawn = math.sqrt(
        (pos.x - npc.spawnPoint.x) ^ 2 + (pos.z - npc.spawnPoint.z) ^ 2
      )

      if distanceFromSpawn > npcConfig.wanderRadius then
        -- Head back towards spawn point
        local angleToSpawn = math.atan2(
          npc.spawnPoint.z - pos.z,
          npc.spawnPoint.x - pos.x
        )
        npc.wanderAngle = angleToSpawn + (lovr.math.random() - 0.5) * math.pi * 0.5
        npc.state = "returning"
      else
        npc.state = "wandering"
      end
    end

    -- Calculate desired velocity from wander direction
    local wanderForce = lovr.math.newVec3(
      math.cos(npc.wanderAngle) * npcConfig.maxSpeed,
      0,
      math.sin(npc.wanderAngle) * npcConfig.maxSpeed
    )

    -- 4. COMBINE ALL FORCES
    -- Avoidance has highest priority
    if avoidanceFound then
      npc.desiredVelocity:add(npc.avoidanceForce:mul(npcSpeed)) -- Strong avoidance
      npc.state = "avoiding"
    end

    -- Add separation force - REMOVED

    -- Add wandering force (lower priority)
    npc.desiredVelocity:add(wanderForce:mul(npcSpeed))

    -- Limit maximum speed (increased limit)
    local maxSpeed = npcConfig.maxSpeed * npcSpeedLimit -- higher speed limit
    if npc.desiredVelocity:length() > maxSpeed then
      npc.desiredVelocity:normalize():mul(maxSpeed)
    end

    -- 5. APPLY FORCES TO PHYSICS BODY
    local currentVelocity = lovr.math.newVec3(npc.body:getLinearVelocity())
    currentVelocity.y = 0 -- Only consider horizontal velocity

    local steeringForce = lovr.math.newVec3(npc.desiredVelocity):sub(currentVelocity)

    -- Apply the steering force to the physics body (increased multiplier)
    npc.body:applyForce(steeringForce.x * 50, 0, steeringForce.z * 50)

    -- Debug: Print NPC movement info for first NPC occasionally
    if npc.id == 1 and math.random() < 0.1 then -- First NPC, 10% chance
      local vx, vy, vz = npc.body:getLinearVelocity()
      local forceApplied = math.sqrt((steeringForce.x * 50) ^ 2 + (steeringForce.z * 50) ^ 2)
      print("DEBUG NPC1 - DesiredVel:", string.format("%.2f", npc.desiredVelocity:length()),
        "Force:", string.format("%.0f", forceApplied),
        "Velocity:", string.format("%.2f", math.sqrt(vx ^ 2 + vz ^ 2)),
        "State:", npc.state)
    end

    -- Rotate NPC collider using the EXACT same logic as model rotation in drawNPCs
    local vel = lovr.math.newVec3(npc.body:getLinearVelocity())
    local npcYaw = 0
    if vel:length() > 0.1 then
      npcYaw = math.atan2(vel.x, vel.z) -- Calculate yaw from velocity direction (same as model)
    else
      npcYaw = npc.wanderAngle or 0     -- Use wander angle if not moving (same as model)
    end

    -- Set orientation using angle-axis format (much simpler and more reliable)
    npc.body:setOrientation(npcYaw, 0, 1, 0) -- angle, ax, ay, az format

    -- Debug: Print rotation info for first NPC occasionally
    if npc.id == 1 and math.random() < 0.02 then -- First NPC, 2% chance
      -- Check what the angle-axis actually is after setting it
      local angle, ax, ay, az = npc.body:getOrientation()

      print("DEBUG: NPC1 - Vel:", string.format("%.2f", vel:length()),
        "Yaw:", string.format("%.1f°", math.deg(npcYaw)),
        "WanderAngle:", string.format("%.1f°", math.deg(npc.wanderAngle or 0)),
        "AngleAxis:", string.format("%.1f°, %.3f,%.3f,%.3f", math.deg(angle), ax, ay, az))
    end

    -- Keep NPCs upright (reset angular velocity after setting orientation)
    npc.body:setAngularVelocity(0, 0, 0)
  end

  -- Send NPC updates to clients if we're the host
  if multiplayerMode == "host" and multiplayerClient and multiplayerClient:isConnected() then
    if lovr.timer.getTime() - lastNPCNetworkUpdate > npcNetworkUpdateRate then
      for _, npc in ipairs(npcs) do
        local x, y, z = npc.body:getPosition()
        local velX, velY, velZ = npc.body:getLinearVelocity()
        local angVelX, angVelY, angVelZ = npc.body:getAngularVelocity()

        local vel = lovr.math.newVec3(velX, velY, velZ)
        local yaw = 0
        if vel:length() > 0.1 then
          yaw = math.atan2(vel.x, vel.z)
        else
          yaw = npc.wanderAngle or 0
        end

        -- Calculate the current steering force being applied (from the last update)
        local currentVelocity = lovr.math.newVec3(velX, 0, velZ)
        local steeringForce = lovr.math.newVec3(npc.desiredVelocity or lovr.math.newVec3(0, 0, 0)):sub(currentVelocity)
        local forceX, forceY, forceZ = steeringForce.x * 50, 0, steeringForce.z * 50

        local npcData = {
          id = npc.id,
          x = x,
          y = y,
          z = z,
          yaw = yaw,
          state = npc.state,
          color = npc.color,
          velX = velX,
          velY = velY,
          velZ = velZ,
          angVelX = angVelX,
          angVelY = angVelY,
          angVelZ = angVelZ,
          forceX = forceX,
          forceY = forceY,
          forceZ = forceZ
        }

        multiplayerClient:sendNPCUpdate(npcData)
      end
      lastNPCNetworkUpdate = lovr.timer.getTime()
    end
  end
end

-- NPC Rendering Function - Call this from the drawing function
function drawNPCs(pass)
  if not npcModel then return end

  -- For clients, draw NPCs received from host; for host/single player, draw local NPCs
  local npcsToRender = {}

  if multiplayerMode == "client" and multiplayerClient then
    -- Client: render NPCs received from host (visual only - no physics)
    npcsToRender = multiplayerClient.npcsFromHost
  else
    -- Host or single player: render local NPCs
    if not npcs then return end
    npcsToRender = npcs
  end

  -- Get player position for distance calculation
  local playerX, playerY, playerZ = 0, 0, 0
  if player then
    playerX, playerY, playerZ = player:getPosition()
  end

  local npcsRendered = 0
  local totalNPCs = 0
  for _ in pairs(npcsToRender) do totalNPCs = totalNPCs + 1 end

  for _, npc in pairs(npcsToRender) do
    -- Always get current position first for distance calculation
    local x, y, z

    if multiplayerMode == "client" then
      -- Client: use physics body position if available, otherwise fall back to stored position
      if npc.body then
        x, y, z = npc.body:getPosition()
      else
        -- Fallback to stored visual data if no physics body
        x, y, z = npc.position.x, npc.position.y, npc.position.z
      end
    else
      -- Host/single player: use physics body data
      x, y, z = npc.body:getPosition()
    end

    -- Calculate distance from player to NPC for render distance culling
    local distance = math.sqrt((x - playerX) ^ 2 + (y - playerY) ^ 2 + (z - playerZ) ^ 2)

    -- Only render if within render distance
    if distance <= renderDistance then
      -- Now calculate rendering details (yaw, movement, etc.)
      local npcYaw = 0
      local color = npc.color or { 1, 1, 1 } -- Default white if no color
      local isMoving = false

      if multiplayerMode == "client" then
        -- Client: calculate yaw and movement from physics body
        if npc.body then
          -- Calculate yaw from velocity for physics-simulated NPCs
          local vel = lovr.math.newVec3(npc.body:getLinearVelocity())
          if vel:length() > 0.1 then
            npcYaw = math.atan2(vel.x, vel.z)
            isMoving = true
          else
            npcYaw = npc.yaw or 0
            isMoving = false
          end
        else
          -- Fallback to stored visual data if no physics body
          npcYaw = npc.yaw or 0
          isMoving = true -- Assume NPCs are always animated when received from host
        end
      else
        -- Host/single player: calculate facing direction based on velocity
        local vel = lovr.math.newVec3(npc.body:getLinearVelocity())
        if vel:length() > 0.1 then
          npcYaw = math.atan2(vel.x, vel.z) -- Calculate yaw from velocity direction
          isMoving = true
        else
          npcYaw = npc.wanderAngle or 0 -- Use wander angle if not moving
          isMoving = false
        end
      end
      -- Draw NPC using player model
      pass:push()
      pass:translate(x, y + npcModelHeightOffset, z) -- Use NPC-specific height offset
      pass:rotate(npcYaw, 0, 1, 0)                   -- Rotate to face movement direction
      pass:scale(0.49, 0.49, 0.49)                   -- Same scale as other players

      -- Set color tint for the NPC to distinguish from players
      pass:setColor(color[1], color[2], color[3])

      -- Animate the model if NPC is moving
      if isMoving then
        npcModel:animate(1, lovr.timer.getTime())
      end

      pass:draw(npcModel)
      pass:pop()

      npcsRendered = npcsRendered + 1

      -- Debug: Draw NPC collider if debug is enabled (for physics-based NPCs on both host and client)
      if _G.showColliderDebug and npc.body then
        -- Different colors for host vs client NPCs
        if multiplayerMode == "client" then
          pass:setColor(1, 0, 1, 0.3) -- Semi-transparent magenta for client physics NPCs
        else
          pass:setColor(0, 0, 1, 0.3) -- Semi-transparent blue for host NPCs
        end

        -- Get NPC collider rotation (returns angle-axis format: angle, ax, ay, az)
        local angle, ax, ay, az = npc.body:getOrientation()

        -- Debug: Print angle-axis values for first NPC occasionally
        if (npc.id == 1 or (multiplayerMode == "client" and npc.id and npc.id == 1)) and math.random() < 0.05 then
          print("DEBUG: NPC1 Collider Angle-Axis: " ..
            string.format("%.1f°, %.3f,%.3f,%.3f", math.deg(angle), ax, ay, az))
        end

        -- Use Pass:box to draw the exact same shape as the physics collider
        -- Apply the same rotation as the physics collider
        pass:push()
        pass:translate(x, y, z)
        pass:rotate(angle, ax, ay, az)                                           -- Apply collider's rotation using angle-axis format
        pass:box(0, 0, 0, boxColliderWidth, boxColliderHeight, boxColliderDepth) -- Use actual box shape dimensions
        pass:pop()
        pass:setColor(1, 1, 1)                                                   -- Reset color
      end

      -- Reset color to white for next objects
      pass:setColor(1, 1, 1)
    end -- End of render distance check
  end   -- End of NPC loop

  -- Debug: Print NPC count occasionally (1% chance per frame)
  if math.random() < 0.01 then
    print("NPCs rendered: " .. npcsRendered .. "/" .. totalNPCs .. " (within " .. renderDistance .. " units)")
  end
end

-- Removed lovr.mirror override to avoid recursion issues
