lib.locale()
local player = Ox.GetPlayer()

---@type OxPropertyObject[]
Properties = {}
---@type OxPropertyVariables[]
PropertyVariables = {}
---@type table<string, string[]>
Permissions = {}
CurrentZone = nil
---@type table<string, function>
local componentActions = {}

---@param componentType string
---@param action function
---@param actionPermissions string[]
function RegisterComponentAction(componentType, action, actionPermissions)
    componentActions[componentType] = action
    Permissions[componentType] = actionPermissions
end
exports('registerComponentAction', RegisterComponentAction)

RegisterComponentAction('stash', function(component)
    return exports.ox_inventory:openInventory('stash', component.name)
end, {locale('all_access')})

local menus = {
    contextMenu = {
        component_menu = true,
        vehicle_list = true
    },
    listMenu = {
        component_menu = true,
    }
}

---@param menu string | string[]
---@param menuType string
function RegisterMenu(menu, menuType)
    if type(menu) == 'string' then
        menus[menuType][menu] = true
    elseif type(menu) == 'table' then
        for i = 1, #menu do
            menus[menuType][menu[i]] = true
        end
    end
end
exports('registerMenu', RegisterMenu)

---@param blip integer
---@param property string
local function setBlipVariables(blip, property)
    local variables = PropertyVariables[property]
    SetBlipColour(blip, variables.colour)
    SetBlipShrink(blip, true)

    if variables.owner ~= player.charId and not (variables.group and player.getGroups(variables.group)) then
        SetBlipAsShortRange(blip, true)
    end
end

---@type table<string, integer>
local blipRegistry = {}

AddStateBagChangeHandler("", 'global', function(bagName, key, value, reserved, replicated)
    local property = key:match('property%.([%w_]+)')
    if property then
        PropertyVariables[property] = value
        local blip = blipRegistry[property]

        if blip then
            setBlipVariables(blip, property)
        end
    end
end)

local function refreshGroups()
    for name, blip in pairs(blipRegistry) do
        setBlipVariables(blip, name)
    end
end

AddEventHandler('ox:playerLoaded', refreshGroups)
RegisterNetEvent('ox:setGroup', refreshGroups)

---@param point CPoint
local function nearbyPoint(point)
    ---@diagnostic disable-next-line: param-type-mismatch
    DrawMarker(2, point.coords.x, point.coords.y, point.coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.2, 0.15, 30, 30, 150, 222, false, false, 0, true, false, false, false)
end

---@param self CZone
local function onEnter(self)
    CurrentZone = self
    lib.notify({
        title = Properties[self.property].label,
        description = self.name,
        duration = 5000,
        position = 'top'
    })
end

---@param self CZone
local function onExit(self)
    if CurrentZone?.property == self.property and CurrentZone?.componentId == self.componentId then
        CurrentZone = nil
        if menus.contextMenu[lib.getOpenContextMenu()] then lib.hideContext() end
        if menus.listMenu[lib.getOpenMenu()] then lib.hideMenu() end
    end
end

---@type table<string, string[]>
local propertyRegistry = {}
---@type table<string, (CZone | CPoint)[]>
local componentRegistry = {}
local glm = require 'glm'

---@param resource string
---@param file string
local function loadProperty(resource, file)
    local name = file:match('([%w_]+)%..+$')
    propertyRegistry[resource][#propertyRegistry[resource] + 1] = name

    local func, err = load(LoadResourceFile(resource, file), ('@@%s%s'):format(resource, file), 't', Shared.DATA_ENVIRONMENT)
    assert(func, err == nil or ('\n^1%s^7'):format(err))

    local data = func() --[[@as OxPropertyObject]]
    local components = {}

    Properties[name] = data
    Properties[name].name = name
    PropertyVariables[name] = GlobalState[('property.%s'):format(name)]

    if data.blip and data.sprite then
        local blip = AddBlipForCoord(data.blip.x, data.blip.y, 0)
        blipRegistry[name] = blip

        SetBlipSprite(blip, data.sprite)

        if player then
            setBlipVariables(blip, name)
        end

        AddTextEntry(name, data.label)
        BeginTextCommandSetBlipName(name)
        EndTextCommandSetBlipName(blip)
    end

    for i = 1, #data.components do
        local component = data.components[i]
        component.property = name
        component.componentId = i

        if component.point then
            components[i] = lib.points.new({
                coords = component.point,
                distance = 16,
                property = name,
                componentId = i,
                type = component.type,
                name = ('%s:%s'):format(name, i),
                nearby = nearbyPoint,
            })
        else
            local zoneData = lib.zones[component.points and 'poly' or component.box and 'box' or component.sphere and 'sphere']({
                points = component.points,
                thickness = component.thickness,
                coords = component.box or component.sphere,
                rotation = component.rotation,
                size = component.size or vec3(2),
                radius = component.radius,

                onEnter = onEnter,
                onExit = onExit,

                property = name,
                componentId = i,
                name = component.name,
                type = component.type
            })

            components[i] = zoneData

            if component.disableGenerators then
                local point1, point2

                if component.sphere then
                    point1, point2 = glm.sphere.maximalContainedAABB(zoneData.coords, zoneData.radius)
                else
                    local verticalOffset = vec(0, 0, zoneData.thickness / 2)
                    point1, point2 = zoneData.polygon:minimalEnclosingAABB()
                    point1 -= verticalOffset
                    point2 += verticalOffset
                end

                SetAllVehicleGeneratorsActiveInArea(point1.x, point1.y, point1.z, point2.x, point2.y, point2.z, false, false)
            end
        end
    end

    componentRegistry[name] = components
end

AddEventHandler('onClientResourceStart', function(resource)
    local count = GetNumResourceMetadata(resource, 'ox_property_data')
    if count < 1 then return end

    propertyRegistry[resource] = {}
    for i = 0, count - 1 do
        loadProperty(resource, GetResourceMetadata(resource, 'ox_property_data', i))
    end
end)

---@param name string
local function unloadProperty(name)
    local propertyComponents = componentRegistry[name]

    if propertyComponents then
        for i = 1, #propertyComponents do
            propertyComponents[i]:remove()
        end

        componentRegistry[name] = nil
    end

    local blip = blipRegistry[name]

    if blip then
        RemoveBlip(blip)
    end

    Properties[name] = nil
end

RegisterNetEvent('onResourceStop', function(resource)
    local resourceProperties = propertyRegistry[resource]
    if not resourceProperties then return end

    for i = 1, #resourceProperties do
        unloadProperty(resourceProperties[i])
    end
    propertyRegistry[resource] = nil
end)

---@return { property: string, componentId: integer, name: string, type: string }? component
local function getCurrentComponent()
    local closestPoint = lib.points.getClosestPoint()

    if closestPoint and closestPoint.currentDistance < 1 then
        return {
            property = closestPoint.property,
            componentId = closestPoint.componentId,
            name = closestPoint.name,
            type = closestPoint.type
        }
    elseif CurrentZone then
        return {
            property = CurrentZone.property,
            componentId = CurrentZone.componentId,
            name = CurrentZone.name,
            type = CurrentZone.type
        }
    end
end
exports('getCurrentComponent', getCurrentComponent)

exports('getPropertyData', function(property, componentId)
    if not property then
        local component = getCurrentComponent()
        if not component then return false end

        return Properties[component.property].components[component.componentId]
    elseif not componentId then
        return Properties[property]
    end

    return Properties[property].components[componentId]
end)

---@param property? string
---@param componentId? integer
---@return false | integer response
local function isPermitted(property, componentId)
    if not property or not componentId then
        local component = getCurrentComponent()
        if not component then return false end

        property = component.property
        componentId = component.componentId
    end

    local variables = PropertyVariables[property]

    -- Check if player is the owner if so, give full access
    if player.charId == variables.owner then
        return 1
    end

    -- Check if player is maximum group grade (owner of group if so, give full access)
    local group = variables.group
    if group and player.getGroup(group) == #GlobalState[('group.%s'):format(group)].grades then
        return 1
    end

    if next(variables.permissions) then
        for i = 1, #variables.permissions do
            local level = variables.permissions[i]
            
            local access = i == 1 and 1 or level.components[componentId]

            if access and (level.everyone or (level.players and level.players[player.charId]) or group and player.getGroup(level.groups)) then
                return access
            end
        end
    end

    lib.notify({title = locale('permission_denied'), type = 'error'})
    return false
end
exports('isPermitted', isPermitted)

RegisterCommand('triggerComponent', function()
    if menus.contextMenu[lib.getOpenContextMenu()] then lib.hideContext() return end
    if menus.listMenu[lib.getOpenMenu()] then lib.hideMenu() return end
    if IsPauseMenuActive() or IsNuiFocused() then return end

    local component = getCurrentComponent()
    if not component or not isPermitted(component.property, component.componentId) then return end

    local data, actionType = componentActions[component.type](component)
    if not data or not actionType then return end

    if actionType == 'event' then
        TriggerEvent(data.event, data.args)
    elseif actionType == 'serverEvent' then
        TriggerServerEvent(data.serverEvent, data.args)
    elseif actionType == 'listMenu' then
        lib.registerMenu({
            id = 'component_menu',
            title = data.title or component.name,
            options = data.options,
            position = data.position or 'top-left',
            disableInput = data.disableInput,
            canClose = data.canClose,
            onClose = data.onClose,
            onSelected = data.onSelected,
            onSideScroll = data.onSideScroll,
            onCheck = data.onCheck,
        }, data.cb)
        lib.showMenu('component_menu')
    elseif actionType == 'contextMenu' then
        local menu = {
            id = 'component_menu',
            title = data.title or ('%s - %s'):format(Properties[component.property].label, component.name),
            canClose = data.canClose,
            onExit = data.onExit,
            options = data.options
        }

        if type(data.subMenus) == 'table' then
            for i = 1, #data.subMenus do
                menu[i] = data.subMenus[i]
            end
        end

        lib.registerContext(menu)
        lib.showContext('component_menu')
    end
end)
RegisterKeyMapping('triggerComponent', 'Trigger Component', 'keyboard', 'e')


---local managmentData = lib.callback.await('ox_property:admin_management', 100, 'get_data', data)
RegisterNetEvent('ox_property:context:handle_property_option', function (data)
    local managmentData = lib.callback.await('ox_property:admin_management', 100, 'get_data', data)

    local options = {}

    if data.msg == 'set_owner' then
       --[[  options = {{
            title = 'Manual Select',
            onSelect = function ()
                local id
                local success = false
                local input = lib.inputDialog(locale('set_new_property_owner'), {
                    {type = 'number', label = 'Enter ID', description = 'It can be either charId or serverId', icon = 'hashtag'},
                    {type = 'checkbox', label = 'charId'},
                    {type = 'checkbox', label = 'Remove Owner'},
                    })
            
                if input[3] then
                    id = 0
                    success = true
                else
                    if input[1] == nil then
                        lib.notify({
                            title = 'Error',
                            description = 'You need to provide id',
                            type = 'error'
                        })
                    else
                        if input[2] then
                            id = input[1]
                            success = true
                        else
                            local targetPlayer = lib.callback.await('ox_property:getoxplayer', source, input[1])
                            if targetPlayer then
                                id = targetPlayer.charId
                                success = true
                            else
                                lib.notify({
                                    title = 'Error',
                                    description = 'No player with ID ' .. input[1] .. ' was found',
                                    type = 'error'
                                })
                            end
                        end
                    end
                end
            
                if success then
                    local data = {
                        property = data.property,
                        owner = id
                    }
    
                    local result = lib.callback.await('ox_property:admin_management', 100, 'set_value', data)
                    if result then
                        lib.notify({
                            title = 'Success',
                            description = 'Action successful',
                            type = 'success'
                        })
                    end
                end
            end
        }} ]]
        for key, value in pairs(managmentData) do
            for component, component_value in pairs(value) do
                if key == "allPlayers" then
                    options[#options+1] = {
                        title = component_value.name,
                        onSelect = function ()
                            local args = {
                                property = data.property,
                                owner = component_value.charId
                            }
                            local result = lib.callback.await('ox_property:admin_management', 100, 'set_value', args)
                            if result then
                                lib.notify({
                                    title = 'Success',
                                    description = 'Action successful',
                                    type = 'success'
                                })
                            end
                        end
                    }
                end
            end
        end
    elseif data.msg == 'set_group' then
        for key, value in pairs(managmentData) do
            for component, component_value in pairs(value) do
                if key == "groups" then
                    options = {
                        {
                            title = locale('none'),
                            onSelect = function ()
                                local args = {
                                    property = data.property,
                                    group = 0
                                }
                                local result = lib.callback.await('ox_property:admin_management', 100, 'set_value', args)
                                if result then
                                    lib.notify({
                                        title = 'Success',
                                        description = 'Action successful',
                                        type = 'success'
                                    })
                                end
                            end
                        }
                    }

                    options[#options+1] = {
                        title = component_value.label .. " | " .. component_value.name,
                        onSelect = function ()
                            local args = {
                                property = data.property,
                                group = component_value.name
                            }
                            local result = lib.callback.await('ox_property:admin_management', 100, 'set_value', args)
                            if result then
                                lib.notify({
                                    title = 'Success',
                                    description = 'Action successful',
                                    type = 'success'
                                })
                            end
                        end
                    }
                end
            end
        end
    end

    lib.registerContext({
        id = 'ox_property:propertymenu_setproperty',
        title = "Set New Owner",
        menu = 'ox_property:propertymenu',
        options = options
    })
    
    lib.showContext('ox_property:propertymenu_setproperty')
end)

RegisterNetEvent('ox_property:context:manage_property', function(args)
    lib.registerContext({
      id = 'ox_property:propertymenu',
      title = locale('property_managment_title', args.propertyLabel),
      menu = 'context_property',
      options = {
        {
            title = 'Set New Owner',
            event = 'ox_property:context:handle_property_option',
            args = {
                property = args.property,
                msg = 'set_owner'
            }
        },
        {
            title = 'Set New Group',
            event = 'ox_property:context:handle_property_option',
            args = {
                property = args.property,
                msg = 'set_group'
            }
        }
      }
    })

    lib.showContext('ox_property:propertymenu')
  end)

RegisterNetEvent('ox_property:propertymanagment', function(data)
    local options = {}
    for property, object in pairs(Properties) do
        local information = {}
        for propertyId, variables in pairs(PropertyVariables) do
            if propertyId == property then
                for key, value in pairs(variables) do
                    if key == "ownerName" or key == "owner" or key == "group" or key == "groupName" then
                        information[#information+1] = {
                            label = key,
                            value = value
                        }
                    end
                end

                if #information == 0 then
                    information = {locale('none')}
                end

                options[#options+1] = {
                    title = object.label,
                    metadata = information,
                    event = 'ox_property:context:manage_property',
                    args = {
                        property = property,
                        components = object.components,
                        propertyLabel = object.label,
                    },
                }
            end
        end
    end


    local context = {
        id = 'context_property',
        title = locale('property_managment_admin_title'),
        canClose = true,
        options = options
    }

    lib.registerContext(context)

    lib.showContext('context_property')
end)