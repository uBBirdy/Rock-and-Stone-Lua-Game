# Rock and Stone - Multiplayer Guide

A VR/Desktop multiplayer game built with LOVR (Lua VR framework) featuring physics-based interactions, NPCs, and real-time networking.

## 🎮 Game Overview

Rock and Stone is a multiplayer VR/desktop game where players can explore environments, interact with NPCs, and enjoy physics-based gameplay together. The game supports both VR headsets and desktop play, making it accessible to all players.

## 🔧 System Requirements

### Minimum Requirements
- **LOVR Framework**: Latest version (0.17.0+)
- **Operating System**: Windows 10/11, macOS, or Linux
- **RAM**: 4GB minimum, 8GB recommended
- **Graphics**: DirectX 11 compatible graphics card
- **Network**: Stable internet connection for multiplayer

### VR Requirements (Optional)
- **VR Headset**: Oculus Rift/Quest, HTC Vive, Valve Index, or any OpenVR compatible headset
- **Play Space**: 2m x 2m minimum recommended
- **Controllers**: VR hand controllers

### Dependencies
- **ENet**: For multiplayer networking (included)
- **LOVR Mouse Module**: For desktop controls (included)

## 📦 Installation

1. **Install LOVR**: Download and install LOVR from [lovr.org](https://lovr.org)
2. **Download Game**: Clone or download the Rock and Stone game files
3. **Verify Structure**: Ensure all files are in the correct directory structure:
   ```
   Rock_and_Stone_Lua_Game/
   ├── main.lua
   ├── conf.lua
   ├── lovr-mouse.lua
   ├── scene.gltf
   ├── scene.bin
   ├── textures/
   └── rockModel/
   ```

## 🌐 Multiplayer Setup

### Hosting a Game

1. **Launch as Host**:
   ```bash
   lovr . --mode=host --port=6789
   ```
   Or modify the game code to set `multiplayerMode = "host"`

2. **Configure Network**:
   - Default port: `6789`
   - Ensure firewall allows incoming connections on your chosen port
   - Share your public IP address with players who want to join

3. **Port Forwarding** (if needed):
   - Forward the game port (default 6789) in your router settings
   - Use tools like UPnP if supported by your router

### Joining a Game

1. **Launch as Client**:
   ```bash
   lovr . --mode=client --host=<SERVER_IP> --port=6789
   ```
   Or modify the game code to set:
   ```lua
   multiplayerMode = "client"
   serverAddress = "SERVER_IP_HERE"
   serverPort = 6789
   ```

2. **Connection Process**:
   - The game will automatically attempt to connect to the specified server
   - Wait for "Connected to server!" message
   - You'll be assigned a unique player ID

### Single Player Mode

Launch without any multiplayer parameters:
```bash
lovr .
```

## 🎯 Game Features

### Player Interactions
- **Movement**: WASD keys (desktop) or VR locomotion
- **Physics**: Realistic player-to-player collisions
- **Synchronization**: Real-time position and rotation updates
- **Visual Feedback**: See other players' movements and actions

### NPC System
- **AI NPCs**: Physics-based non-player characters
- **Host Authority**: NPCs are controlled by the game host
- **Player Interaction**: Push and interact with NPCs
- **State Synchronization**: NPC positions and states sync across all clients

### Physics Engine
- **Collision Detection**: Players and NPCs have realistic physics bodies
- **Force Application**: Push objects and other players
- **Damage System**: Physics-based interactions
- **Environmental Interaction**: Interact with the game world

### Graphics Features
- **Shadow Mapping**: Dynamic shadows for enhanced visual quality
- **3D Models**: High-quality player and NPC models
- **Lighting**: Advanced lighting system with real-time shadows
- **Textures**: Detailed textures for immersive environments

## 🎮 Controls

### Desktop Mode
- **Movement**: `WASD` keys
- **Mouse Look**: Move mouse to look around
- **Jump**: `Space` bar
- **Interact**: Mouse clicks for interactions
- **Exit**: `Escape` key

### VR Mode
- **Movement**: Thumbstick locomotion or room-scale tracking
- **Interaction**: Hand tracking and controller buttons
- **Grabbing**: Grip buttons to interact with objects
- **Menu**: Menu button for game options

## 🔧 Configuration

### Network Settings
Edit these variables in `main.lua`:
```lua
local serverAddress = "localhost"  -- Server IP address
local serverPort = 6789           -- Server port
local multiplayerMode = "single"  -- "host", "client", or "single"
```

### Physics Parameters
```lua
local playerJumpForce = 1000      -- Jump strength
local playerNPCSpeed = 1200       -- Player movement speed
local npcSpeedLimit = 15          -- NPC maximum speed
```

### Graphics Settings
```lua
local shadow_map_size = 4096      -- Shadow quality (higher = better quality)
local light_intensity = 1        -- Lighting strength
local debug_show_shadow_map = false -- Debug shadow rendering
```

## 🐛 Troubleshooting

### Connection Issues

**"Failed to create ENet host"**
- Ensure ENet library is properly installed
- Check that the port isn't already in use
- Try running as administrator (Windows)

**"Failed to connect to server"**
- Verify server IP address and port
- Check firewall settings on both client and server
- Ensure host is running and accepting connections

**"Connection timeout"**
- Check internet connectivity
- Verify port forwarding configuration
- Try connecting locally first (127.0.0.1)

### Performance Issues

**Low FPS**
- Reduce `shadow_map_size` in configuration
- Disable VR mode if not needed
- Close other applications

**Network Lag**
- Check ping with the ping command in-game
- Ensure stable internet connection
- Host should have good upload speed

### VR-Specific Issues

**Tracking Problems**
- Ensure adequate lighting in play space
- Check VR headset setup and calibration
- Verify controllers are charged and paired

**Motion Sickness**
- Use teleportation locomotion instead of smooth movement
- Take frequent breaks
- Adjust comfort settings in VR software

## 🌐 Network Architecture

### Client-Server Model
- **Host Authority**: The host controls all NPCs and physics simulation
- **Client Prediction**: Clients predict their own movement for responsiveness
- **State Synchronization**: Regular updates ensure all clients stay in sync

### Message Types
- **PLAYER_UPDATE**: Position and rotation data (sent frequently)
- **NPC_UPDATE**: NPC state and physics data (host only)
- **NPC_PUSH**: Client notifications of NPC interactions
- **JOIN_GAME**: Initial connection and player setup
- **PING**: Network latency measurement

### Network Optimization
- **Unreliable Updates**: Position data uses UDP for speed
- **Reliable Messages**: Important events use TCP for accuracy
- **Compression**: Efficient data formatting reduces bandwidth

## 🔍 Advanced Features

### Developer Tools
- **Debug Rendering**: Enable debug modes for troubleshooting
- **Console Output**: Detailed logging for development
- **Physics Visualization**: See collision boundaries and forces

### Modding Support
- **Lua Scripting**: Easily modify game behavior
- **Asset Loading**: Support for custom models and textures
- **Configuration Files**: Extensive customization options

## 📋 Server Management

### Hosting Best Practices
1. **Stable Connection**: Use wired internet connection
2. **Port Management**: Keep firewall rules updated
3. **Player Limits**: Monitor performance with multiple players
4. **Regular Backups**: Save game states if persistence is added

### Monitoring
- Check console output for connection status
- Monitor ping times for all connected players
- Watch for physics simulation issues

## 🤝 Contributing

### Bug Reports
- Include console output and error messages
- Describe steps to reproduce the issue
- Specify your system configuration

### Feature Requests
- Explain the desired functionality
- Consider multiplayer implications
- Provide implementation suggestions if possible

## 📄 License

This project uses the LOVR framework and includes various open-source components. Please respect all applicable licenses when using or modifying this code.

## 🆘 Support

For additional help:
1. Check the console output for detailed error messages
2. Review the troubleshooting section above
3. Ensure all dependencies are properly installed
4. Test in single-player mode first to isolate networking issues

---

**Rock and Stone!** 🪨⚡

*Have fun exploring the multiplayer world together!* 