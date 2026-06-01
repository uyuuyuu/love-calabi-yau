----------------------------------------------------------------------------------------------------
-- matrix helper functions
----------------------------------------------------------------------------------------------------

function IdentityMatrix()
    return {1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}
end

function GetMatrixXY(matrix, x,y)
    return matrix[x + (y-1)*4]
end

function MatrixMult(a,b)
    local ret = {0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0}
    local i = 1
    for y=1, 4 do
        for x=1, 4 do
            ret[i] = ret[i] + GetMatrixXY(a,1,y)*GetMatrixXY(b,x,1)
            ret[i] = ret[i] + GetMatrixXY(a,2,y)*GetMatrixXY(b,x,2)
            ret[i] = ret[i] + GetMatrixXY(a,3,y)*GetMatrixXY(b,x,3)
            ret[i] = ret[i] + GetMatrixXY(a,4,y)*GetMatrixXY(b,x,4)
            i = i + 1
        end
    end
    return ret
end

function GetTransformationMatrix(translation, rotation, scale)
    local ret = IdentityMatrix()
    ret[4] = translation[1]
    ret[8] = translation[2]
    ret[12] = translation[3]

    local rx = IdentityMatrix()
    rx[6] = math.cos(rotation[1])
    rx[7] = -1*math.sin(rotation[1])
    rx[10] = math.sin(rotation[1])
    rx[11] = math.cos(rotation[1])
    ret = MatrixMult(ret, rx)

    local ry = IdentityMatrix()
    ry[1] = math.cos(rotation[2])
    ry[3] = math.sin(rotation[2])
    ry[9] = -math.sin(rotation[2])
    ry[11] = math.cos(rotation[2])
    ret = MatrixMult(ret, ry)

    local rz = IdentityMatrix()
    rz[1] = math.cos(rotation[3])
    rz[2] = -math.sin(rotation[3])
    rz[5] = math.sin(rotation[3])
    rz[6] = math.cos(rotation[3])
    ret = MatrixMult(ret, rz)

    local s = IdentityMatrix()
    s[1] = scale[1]
    s[6] = scale[2]
    s[11] = scale[3]
    ret = MatrixMult(ret, s)

    return ret
end

function GetProjectionMatrix(fov, near, far, aspectRatio)
    local top = near * math.tan(fov/2)
    local bottom = -1*top
    local right = top * aspectRatio
    local left = -1*right
    return {
        2*near/(right-left), 0, (right+left)/(right-left), 0,
        0, 2*near/(top-bottom), (top+bottom)/(top-bottom), 0,
        0, 0, -1*(far+near)/(far-near), -2*far*near/(far-near),
        0, 0, -1, 0
    }
end

function GetViewMatrix(eye, target, down)
    local function normalize(v)
        local d = math.sqrt(v[1]^2 + v[2]^2 + v[3]^2)
        return {v[1]/d, v[2]/d, v[3]/d}
    end
    local function cross(a,b)
        return {a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1]}
    end
    local function dot(a,b)
        return a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
    end

    local z = normalize({eye[1] - target[1], eye[2] - target[2], eye[3] - target[3]})
    local x = normalize(cross(down, z))
    local y = cross(z, x)

    return {
        x[1], x[2], x[3], -1*dot(x, eye),
        y[1], y[2], y[3], -1*dot(y, eye),
        z[1], z[2], z[3], -1*dot(z, eye),
        0, 0, 0, 1,
    }
end

local shader
local mesh
local rotationQuat = {0, 0, 0, 1}
local cameraDistance = 9.5
local alpha = 0.3 * math.pi
local globalScale = 1.75

-- Interaction state
local meshMode = 1 -- 1: Solid, 2: Wireframe, 3: Points
local isLocked = false
local showInfo = true
local velX, velY = 0.01, 0.005 -- Initial drift

-- Advanced state
local colorShift = 0
local autoRotate = false
local colorCycle = true
local tripMode = false
local tripTimer = 0
local STEPS_U = 36
local STEPS_V = 24
local PATCHES = 5

-- Dolly Zoom / Ortho transition state
local dollyFactor = 0 -- 0: Perspective, 1: Near-Ortho
local baseFOV = math.pi/3
local baseDistance = 9.5

-- Visual polish
local bloomEnabled = true
local starsEnabled = true
local starsMesh
local bloomCanvas, blurCanvas
local blurShader

function generateStars(format)
    local vertices = {}
    for i=1, 3000 do
        local x = (math.random() - 0.5) * 150
        local y = (math.random() - 0.5) * 150
        local z = (math.random() - 0.5) * 150
        local r = math.random(150, 255) / 255
        table.insert(vertices, {x, y, z, r, r, r, 0.8})
    end
    starsMesh = love.graphics.newMesh(format, vertices, "points")
end

function quatMultiply(a, b)
    return {
        a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
        a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
        a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
        a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3]
    }
end

function love.load()
    love.graphics.setBackgroundColor(0.02, 0.02, 0.04)
    love.graphics.setDepthMode("lequal", true)

    shader = love.graphics.newShader("shader.glsl")

    -- Setup Bloom
    local w, h = love.graphics.getDimensions()
    -- Enable depth buffer for the 3D rendering canvas
    bloomCanvas = love.graphics.newCanvas(w, h)
    -- Blur canvas is 2D, depth not needed
    blurCanvas = love.graphics.newCanvas(w, h)

    blurShader = love.graphics.newShader([[
        extern vec2 direction;
        vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
            vec4 sum = vec4(0.0);
            sum += Texel(tex, tc - 4.0*direction) * 0.05;
            sum += Texel(tex, tc - 3.0*direction) * 0.09;
            sum += Texel(tex, tc - 2.0*direction) * 0.12;
            sum += Texel(tex, tc - 1.0*direction) * 0.15;
            sum += Texel(tex, tc) * 0.16;
            sum += Texel(tex, tc + 1.0*direction) * 0.15;
            sum += Texel(tex, tc + 2.0*direction) * 0.12;
            sum += Texel(tex, tc + 3.0*direction) * 0.09;
            sum += Texel(tex, tc + 4.0*direction) * 0.05;
            return sum;
        }
    ]])

    generateWireframeMesh()
    generateStars({
        {"VertexPosition", "float", 3},
        {"VertexColor", "float", 4},
    })
end

function getPoint(u, v, k1, k2)
    local phase1 = 2 * math.pi * k1 / 5
    local phase2 = 2 * math.pi * k2 / 5

    local z1x, z1y, z2x, z2y

    if math.abs(u) < 0.001 and math.abs(v) < 0.001 then
        z1x = math.cos(phase1)
        z1y = math.sin(phase1)
        z2x = 0
        z2y = 0
    else
        local r1 = math.pow(math.cos(v), 2 / 5)
        local a1 = u
        z1x = r1 * math.cos(phase1 + a1)
        z1y = r1 * math.sin(phase1 + a1)

        local r2 = math.pow(math.abs(math.sin(v)), 2 / 5)
        local a2 = u + math.pi / 2
        z2x = r2 * math.cos(phase2 + a2)
        z2y = r2 * math.sin(phase2 + a2)
    end

    local px = z2x
    local py = math.cos(alpha) * z1y + math.sin(alpha) * z2y
    local pz = z1x

    return {
        x = px * globalScale,
        y = py * globalScale,
        z = pz * globalScale
    }
end

function generateWireframeMesh()
    local vertices = {}
    local indices = {}
    local idx = 0

    local format = {
        {"VertexPosition", "float", 3},
        {"VertexColor", "float", 4},
    }

    for k1 = 0, PATCHES-1 do
        for k2 = 0, PATCHES-1 do
            local hue = (k1 * 0.2 + k2 * 0.15) / 5
            local r = 0.95 + 0.1 * math.cos(2*math.pi*hue)
            local g = 0.75 + 0.25 * math.cos(2*math.pi*(hue + 0.3))
            local b = 0.45 + 0.3 * math.cos(2*math.pi*(hue + 0.6))

            for j = 0, STEPS_V - 1 do
                for i = 0, STEPS_U - 1 do
                    local u1 = -1.0 + 2.0 * i / STEPS_U
                    local u2 = -1.0 + 2.0 * (i + 1) / STEPS_U
                    local v1 = (0.5 * math.pi) * j / STEPS_V
                    local v2 = (0.5 * math.pi) * (j + 1) / STEPS_V

                    local p1 = getPoint(u1, v1, k1, k2)
                    local p2 = getPoint(u2, v1, k1, k2)
                    local p3 = getPoint(u2, v2, k1, k2)
                    local p4 = getPoint(u1, v2, k1, k2)

                    table.insert(vertices, {p1.x, p1.y, p1.z, r, g, b, 1})
                    table.insert(vertices, {p2.x, p2.y, p2.z, r, g, b, 1})
                    table.insert(vertices, {p3.x, p3.y, p3.z, r, g, b, 1})
                    table.insert(vertices, {p4.x, p4.y, p4.z, r, g, b, 1})

                    table.insert(indices, idx + 1)
                    table.insert(indices, idx + 2)
                    table.insert(indices, idx + 3)
                    table.insert(indices, idx + 1)
                    table.insert(indices, idx + 3)
                    table.insert(indices, idx + 4)
                    idx = idx + 4
                end
            end
        end
    end

    mesh = love.graphics.newMesh(format, vertices, "triangles")
    mesh:setVertexMap(indices)
end

local lastGenAlpha = 0

function love.update(dt)
    -- Color Cycling
    if colorCycle then
        colorShift = colorShift + dt * 0.1
    end

    -- Cinematic Trip Mode
    if tripMode then
        tripTimer = tripTimer + dt

        -- Physical "Motor": Apply torque that evolves smoothly
        -- We interpolate current velocity towards a target velocity that changes organically
        local targetVelX = (math.sin(tripTimer * 0.5) * 0.015 + math.sin(tripTimer * 1.1) * 0.005)
        local targetVelY = (math.cos(tripTimer * 0.3) * 0.015 + math.cos(tripTimer * 0.8) * 0.005)

        -- Smoothly adjust velocity (P-control like interpolation for "heavy" feel)
        local lerpSpeed = 0.8
        velX = velX + (targetVelX - velX) * dt * lerpSpeed
        velY = velY + (targetVelY - velY) * dt * lerpSpeed

        -- Smoothly swing alpha with a spring-like feel
        local alphaTarget = math.pi * (0.3 + 0.18 * math.sin(tripTimer * 0.35))
        alpha = alpha + (alphaTarget - alpha) * dt * 1.2

        -- Threshold check to prevent redundant heavy mesh regeneration
        if math.abs(alpha - lastGenAlpha) > 0.0015 then
            generateWireframeMesh()
            lastGenAlpha = alpha
        end
    end

    -- Dolly Zoom transition logic
    local targetDolly = love.keyboard.isDown("o") and 1 or 0
    local transitionSpeed = 4.0
    if dollyFactor < targetDolly then
        dollyFactor = math.min(targetDolly, dollyFactor + dt * transitionSpeed)
    elseif dollyFactor > targetDolly then
        dollyFactor = math.max(targetDolly, dollyFactor - dt * transitionSpeed)
    end

    if autoRotate and not tripMode then
        -- Apply a small constant torque (acceleration) for physical feel
        velX = velX + 0.01 * dt
    end

    if not isLocked then
        -- Apply rotation based on velocity (frame-rate independent)
        if math.abs(velX) > 0.0001 or math.abs(velY) > 0.0001 then
            local qx_v = {math.sin(velY * 30 * dt * 0.5), 0, 0, math.cos(velY * 30 * dt * 0.5)}
            local qy_v = {0, math.sin(velX * 30 * dt * 0.5), 0, math.cos(velX * 30 * dt * 0.5)}
            rotationQuat = quatMultiply(qy_v, rotationQuat)
            rotationQuat = quatMultiply(qx_v, rotationQuat)

            -- Normalize quat to prevent drift
            local mag = math.sqrt(rotationQuat[1]^2 + rotationQuat[2]^2 + rotationQuat[3]^2 + rotationQuat[4]^2)
            for i=1,4 do rotationQuat[i] = rotationQuat[i] / mag end
        end

        -- Friction: smooth decay of velocity (scaled by dt)
        local friction = 0.96 ^ (dt * 60)
        velX = velX * friction
        velY = velY * friction
    end
end

function love.draw()
    if bloomEnabled then
        love.graphics.setCanvas({bloomCanvas, depth=true})
        love.graphics.clear()
        shader:send("isCanvas", true)
    else
        shader:send("isCanvas", false)
    end

    love.graphics.setShader(shader)
    shader:send("colorShift", colorShift)

    -- Dynamic FOV and Camera Distance for Dolly Zoom
    local currentFOV = baseFOV * (1 - dollyFactor * 0.98)
    local scaleFactor = math.tan(baseFOV/2) / math.tan(currentFOV/2)
    local currentDistance = cameraDistance * scaleFactor

    local aspect = love.graphics.getWidth() / love.graphics.getHeight()
    shader:send("projectionMatrix", GetProjectionMatrix(currentFOV, 0.1, 1000, aspect))
    shader:send("viewMatrix", GetViewMatrix({0, 0, 0}, {0, 0, 1}, {0, 1, 0}))

    -- Convert quaternion to rotation matrix
    local q = rotationQuat
    local xx, xy, xz, xw = q[1]*q[1], q[1]*q[2], q[1]*q[3], q[1]*q[4]
    local yy, yz, yw = q[2]*q[2], q[2]*q[3], q[2]*q[4]
    local zz, zw = q[3]*q[3], q[3]*q[4]

    local rotationMatrix = {
        1 - 2*(yy + zz),     2*(xy - zw),     2*(xz + yw), 0,
            2*(xy + zw), 1 - 2*(xx + zz),     2*(yz - xw), 0,
            2*(xz - yw),     2*(yz + xw), 1 - 2*(xx + yy), 0,
                      0,               0,               0, 1
    }

    -- Render Stars
    if starsEnabled then
        -- Apply only rotation to stars so they stay centered around camera
        shader:send("modelMatrix", rotationMatrix)
        love.graphics.draw(starsMesh)
    end

    local modelMatrix = {
        1 - 2*(yy + zz),     2*(xy - zw),     2*(xz + yw), 0,
            2*(xy + zw), 1 - 2*(xx + zz),     2*(yz - xw), 0,
            2*(xz - yw),     2*(yz + xw), 1 - 2*(xx + yy), currentDistance,
                      0,               0,               0, 1
    }

    shader:send("modelMatrix", modelMatrix)
    -- Set rendering modes based on meshMode
    if meshMode == 1 then -- Solid
        mesh:setDrawMode("triangles")
        love.graphics.setWireframe(false)
    elseif meshMode == 2 then -- Wireframe
        mesh:setDrawMode("triangles")
        love.graphics.setWireframe(true)
    elseif meshMode == 3 then -- Points
        mesh:setDrawMode("points")
        love.graphics.setPointSize(2)
    end

    love.graphics.setMeshCullMode("none")
    love.graphics.draw(mesh)

    love.graphics.setWireframe(false)
    love.graphics.setShader()

    if bloomEnabled then
        love.graphics.setCanvas({depth=true})
        local w, h = love.graphics.getDimensions()

        -- Horizontal blur
        love.graphics.setCanvas(blurCanvas)
        love.graphics.clear()
        love.graphics.setShader(blurShader)
        blurShader:send("direction", {2/w, 0})
        love.graphics.draw(bloomCanvas)

        -- Vertical blur + Combine
        love.graphics.setCanvas({depth=true})
        blurShader:send("direction", {0, 2/h})

        -- Draw original
        love.graphics.setShader()
        love.graphics.draw(bloomCanvas)

        -- Draw glow (additive)
        love.graphics.setBlendMode("add")
        love.graphics.setShader(blurShader)
        love.graphics.draw(blurCanvas)
        love.graphics.setBlendMode("alpha")
        love.graphics.setShader()
    end

    if showInfo then
        -- Calculate Euler angles for display
        -- Standard mapping: X = Pitch, Y = Yaw, Z = Roll
        local qx, qy, qz, qw = q[1], q[2], q[3], q[4]
        local eulerX = math.atan2(2*(qw*qx + qy*qz), 1 - 2*(qx*qx + qy*qy))
        local eulerY = math.asin(math.max(-1, math.min(1, 2*(qw*qy - qz*qx))))
        local eulerZ = math.atan2(2*(qw*qz + qx*qy), 1 - 2*(qy*qy + qz*qz))

        -- Display info
        love.graphics.setColor(1,1,1,0.7)
        love.graphics.print("FPS: " .. love.timer.getFPS(), 10, 10)
        love.graphics.print("Camera Distance: " .. string.format("%.1f", cameraDistance), 10, 30)
        love.graphics.print("Rotation (deg): " .. string.format("P:%.0f Y:%.0f R:%.0f",
            math.deg(eulerX), math.deg(eulerY), math.deg(eulerZ)), 10, 50)
        love.graphics.print("Subdivision (T/Y): " .. STEPS_U .. "x" .. STEPS_V .. " | Patches (P/U): " .. PATCHES, 10, 70)

        local modeNames = {"Solid", "Wireframe", "Points"}
        love.graphics.print("[M] Mesh Mode: " .. modeNames[meshMode], 10, 100)
        love.graphics.print("[L] Lock Mode: " .. (isLocked and "ON (Fixed)" or "OFF (Inertia)"), 10, 120)
        love.graphics.print("[A] Auto-Rotate: " .. (autoRotate and "ON" or "OFF") .. " | [N] Color Cycle: " .. (colorCycle and "ON" or "OFF"), 10, 140)
        love.graphics.print("[C] Cinematic Mode: " .. (tripMode and "ON (Trip!)" or "OFF"), 10, 160)
        love.graphics.print("[[ / ]] Alpha: " .. string.format("%.2f", alpha), 10, 180)
        love.graphics.print("[O] Dolly Zoom (Hold): " .. string.format("%d%%", dollyFactor * 100), 10, 200)
        love.graphics.print("[G/B] Glow / Stars", 10, 220)
        love.graphics.print("[H/K/R] UI / Preset / Reset", 10, 240)
        love.graphics.print("[S] Clean Screenshot", 10, 260)
    end
end

-- ==================== Mouse Interaction ====================
local lastX, lastY = 0, 0
local isDragging = false

function love.mousepressed(x, y, button)
    if button == 1 then
        isDragging = true
        lastX, lastY = x, y
    end
end

function love.mousereleased()
    isDragging = false
end

function love.mousemoved(x, y)
    if isDragging then
        local dx = (x - lastX) * 0.005
        local dy = (lastY - y) * 0.005 -- Inverted: lastY - y instead of y - lastY

        -- Update rotation accumulation
        local qx = {math.sin(dy*0.5), 0, 0, math.cos(dy*0.5)}
        local qy = {0, math.sin(dx*0.5), 0, math.cos(dx*0.5)}
        rotationQuat = quatMultiply(qy, rotationQuat)
        rotationQuat = quatMultiply(qx, rotationQuat)

        -- Normalize
        local mag = math.sqrt(rotationQuat[1]^2 + rotationQuat[2]^2 + rotationQuat[3]^2 + rotationQuat[4]^2)
        for i=1,4 do rotationQuat[i] = rotationQuat[i] / mag end

        -- Set physical velocity for inertia
        velX, velY = dx, dy

        lastX, lastY = x, y
    end
end

function love.keypressed(key)
    if key == "m" then
        meshMode = (meshMode % 3) + 1
    elseif key == "l" then
        isLocked = not isLocked
        if isLocked then
            velX, velY = 0, 0
        end
    elseif key == "a" then
        autoRotate = not autoRotate
    elseif key == "n" then
        colorCycle = not colorCycle
    elseif key == "c" then
        tripMode = not tripMode
        if tripMode then
            tripTimer = 0
            isLocked = false
        end
    elseif key == "p" then
        PATCHES = math.max(1, PATCHES - 1)
        generateWireframeMesh()
    elseif key == "u" then
        PATCHES = math.min(10, PATCHES + 1)
        generateWireframeMesh()
    elseif key == "t" then
        STEPS_U = math.max(4, STEPS_U - 4)
        STEPS_V = math.max(4, STEPS_V - 4)
        generateWireframeMesh()
    elseif key == "y" then
        STEPS_U = math.min(100, STEPS_U + 4)
        STEPS_V = math.min(100, STEPS_V + 4)
        generateWireframeMesh()
    elseif key == "s" then
        -- Clean screenshot (no UI)
        local wasShowing = showInfo
        showInfo = false
        love.draw() -- Render frame without UI
        local filename = "calabi_yau_" .. os.time() .. ".png"
        local screenshot = love.graphics.captureScreenshot(filename)
        showInfo = wasShowing
        print("Screenshot saved to: " .. filename)
    elseif key == "[" then
        alpha = alpha - 0.05
        generateWireframeMesh()
    elseif key == "]" then
        alpha = alpha + 0.05
        generateWireframeMesh()
    elseif key == "g" then
        bloomEnabled = not bloomEnabled
    elseif key == "b" then
        starsEnabled = not starsEnabled
    elseif key == "h" then
        showInfo = not showInfo
    elseif key == "k" then
        -- Set rotation to exactly (P: 0, Y: -45, R: 0)
        local yaw = math.rad(-45)
        rotationQuat = {0, math.sin(yaw/2), 0, math.cos(yaw/2)}
        velX, velY = 0, 0
    elseif key == "r" then
        rotationQuat = {0, 0, 0, 1}
        cameraDistance = 9.5
        velX, velY = 0, 0
        STEPS_U, STEPS_V = 36, 24
        PATCHES = 5
        alpha = 0.3 * math.pi
        tripMode = false
        generateWireframeMesh()
    elseif key == "escape" then
        love.event.quit()
    end
end

function love.wheelmoved(x, y)
    cameraDistance = cameraDistance - y * 0.6
    if cameraDistance < 3 then cameraDistance = 3 end
    if cameraDistance > 25 then cameraDistance = 25 end
end
