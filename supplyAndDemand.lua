------------------------------------------------------------------------
--SETTINGS
------------------------------------------------------------------------
-- How much of each product is demanded annually?
-- (In terms of money value on hard economy setting.)
-- Scales automatically to match difficulty setting.
local annualProductDemand = 75000

-- Maximum years worth of demand that can accumulate.
local demandAccumulationCap = 2.2

-- Maximum price multiplier applied to default prices.
local priceIncreaseLimit = 1.2

-- Minimum price multiplier applied to default prices.
local priceDecreaseLimit = 0.4

-- Minimum hours of no selling before sales impact demand.
-- Prevents price drops on products being actively sold.
local graceHours = 4
------------------------------------------------------------------------
SupplyAndDemand = {}
source(g_currentModDirectory..'supplyAndDemandEvent.lua')

local function clampFactor(factor)
    factor = factor or priceIncreaseLimit
    factor = math.max(factor, priceDecreaseLimit)
    factor = math.min(factor, priceIncreaseLimit)
    return factor
end

local function fetchXML()
    if not g_currentMission:getIsServer() then
        return
    end

    local XMLPath = g_modSettingsDirectory..'SupplyAndDemand.xml'
    local xmlId = 0
    local savePath = 'root.savegame'..tostring(g_currentMission.missionInfo.savegameIndex)
    if fileExists(XMLPath) then
        xmlId = loadXMLFile('SupplyAndDemandXML', XMLPath)
    else
        xmlId = createXMLFile('SupplyAndDemandXML', XMLPath, 'root')
    end

    return xmlId ~= 0 and xmlId or nil, savePath
end

local function broadcastFactors()
    local fillTypeFactors = {}
    for index, fillType in pairs(g_fillTypeManager.fillTypes) do
        fillTypeFactors[fillType.name] = fillType.factor
    end

    local subTypeFactors = {}
    for index, subType in pairs(g_currentMission.animalSystem.subTypes) do
        subTypeFactors[subType.name] = subType.factor
    end

    if g_server ~= nil then
        g_server:broadcastEvent(
            SupplyAndDemandEvent.new(fillTypeFactors, subTypeFactors)
        )
    else
        g_client:getServerConnection():sendEvent(
            SupplyAndDemandEvent.new(fillTypeFactors, subTypeFactors)
        )
    end 
end

local function catchSubTypeSale(sellerInfo, func, ...)
    if sellerInfo.sellPrice then
        local clusterId = sellerInfo.clusterId
        local subTypeIndex = sellerInfo.object:getClusterById(clusterId).subTypeIndex
        local subType = g_currentMission.animalSystem.subTypes[subTypeIndex]
        if not subType.recentSold then
            populateMissingDataPoints()
        end

        subType.recentSold = subType.recentSold + sellerInfo.sellPrice
        subType.graceHours = graceHours
    end

    return func(sellerInfo, ...)
end

local function catchFillTypeSale(_, _, amountLiters, fillTypeIndex)
    local fillType = g_fillTypeManager.fillTypes[fillTypeIndex]
    if not fillType.recentSold then
        populateMissingDataPoints()
    end

    fillType.recentSold = fillType.recentSold + amountLiters
    fillType.graceHours = graceHours
end

local function repriceSubType(subType)
    local function reprice(sellerInfo, func, ...)
        return func(sellerInfo, ...) * clampFactor(subType.factor)
    end

    return reprice
end

local function repriceFillType(sellerInfo, func, fillTypeIndex, ...)
    local fillType = g_fillTypeManager.fillTypes[fillTypeIndex]
    if not fillType.factor then
        populateMissingDataPoints()
    end

    return func(sellerInfo, fillTypeIndex, ...) * clampFactor(fillType.factor)
end

local function loadXMLData()
    local xmlId, savePath = fetchXML()
    if not xmlId then
        return
    end

    local XMLData = {fillTypes = {}, subTypes = {}}
    local index = 0
    while hasXMLProperty(xmlId, savePath..'.fillType('..index..')') do
        local fillTypePath = savePath..'.fillType('..index..')'
        local fillType = {
            recentSold = getXMLFloat(xmlId, fillTypePath..'#recentSold'),
            factor = getXMLFloat(xmlId, fillTypePath..'#factor'),
            graceHours = getXMLInt(xmlId, fillTypePath..'#graceHours')
        }
        local fillTypeName = getXMLString(xmlId, fillTypePath..'#name')
        XMLData.fillTypes[fillTypeName] = fillType
        index = index + 1
    end

    index = 0
    while hasXMLProperty(xmlId, savePath..'.subType('..index..')') do
        local subTypePath = savePath..'.subType('..index..')'
        local subType = {
            recentSold = getXMLFloat(xmlId, subTypePath..'#recentSold'),
            factor = getXMLFloat(xmlId, subTypePath..'#factor'),
            graceHours = getXMLInt(xmlId, subTypePath..'#graceHours')
        }
        local subTypeName = getXMLString(xmlId, subTypePath..'#name')
        XMLData.subTypes[subTypeName] = subType
        index = index + 1
    end

    return XMLData
end

local function populateMissingDataPoints()
    local XMLData = loadXMLData()
    for index, fillType in pairs(g_fillTypeManager:getFillTypes()) do
        local XMLFillType = XMLData.fillTypes[fillType.name]
        fillType.recentSold = fillType.recentSold or (XMLFillType and XMLFillType.recentSold) or 0
        fillType.factor = fillType.factor or (XMLFillType and XMLFillType.factor) or demandAccumulationCap
        fillType.graceHours = fillType.graceHours or (XMLFillType and XMLFillType.graceHours) or 0
    end

    for index, subType in pairs(g_currentMission.animalSystem.subTypes) do
        local XMLSubType = XMLData.subTypes[subType.name]
        subType.recentSold = subType.recentSold or (XMLSubType and XMLSubType.recentSold) or 0
        subType.factor = subType.factor or (XMLSubType and XMLSubType.factor) or demandAccumulationCap
        subType.graceHours = subType.graceHours or (XMLSubType and XMLSubType.graceHours) or 0
        if not subType.reprice then
            subType.reprice = repriceSubType(subType.name)
            subType.sellPrice.interpolator = Utils.overwrittenFunction(subType.sellPrice.interpolator, subType.reprice)
        end
    end
end

local function loadXML()
    local xmlId, savePath = fetchXML()
    if not xmlId then
        return
    end

    if not g_currentMission.missionInfo.savegameDirectory then
        if hasXMLProperty(xmlId, savePath) then
            removeXMLProperty(xmlId, savePath)
        end
    end

    local savePath = 'SupplyAndDemand.savegame'..tostring(g_currentMission.missionInfo.savegameIndex)
    if not g_currentMission.missionInfo.savegameDirectory and hasXMLProperty(xmlId, savePath) then
        removeXMLProperty(xmlId, savePath)
    end

    saveXMLFile(xmlId)
    delete(xmlId)
    populateMissingDataPoints()
end

local function saveXML()
    local XMLPath = g_modSettingsDirectory..'SupplyAndDemand.xml'
    local xmlId, savePath = fetchXML()
    if not xmlId then
        return
    end

    populateMissingDataPoints()
    if hasXMLProperty(xmlId, savePath) then
        removeXMLProperty(xmlId, savePath)
    end

    for index, fillType in pairs(g_fillTypeManager.fillTypes) do
        local fillTypePath = savePath..'.fillType('..tostring(index - 1)..')'
        setXMLString(xmlId, fillTypePath..'#name', fillType.name)
        setXMLFloat(xmlId, fillTypePath..'#recentSold', fillType.recentSold)
        setXMLFloat(xmlId, fillTypePath..'#factor', fillType.factor)
        setXMLInt(xmlId, fillTypePath.."#graceHours", fillType.graceHours)
    end

    for index, subType in pairs(g_currentMission.animalSystem.subTypes) do
        local subTypePath = savePath..'.subType('..tostring(index - 1)..')'
        setXMLString(xmlId, subTypePath..'#name', subType.name)
        setXMLFloat(xmlId, subTypePath..'#recentSold', subType.recentSold)
        setXMLFloat(xmlId, subTypePath..'#factor', subType.factor)
        setXMLInt(xmlId, subTypePath..'#graceHours', subType.graceHours)
    end

    saveXMLFile(xmlId)
    delete(xmlId)
end

local function hourlyUpdate()
    local growthModeScale = g_currentMission.missionInfo.growthMode % 3
    local daysPerMonthScale = 1 / g_currentMission.missionInfo.plannedDaysPerPeriod
    local demandIncrease = (1 / 288) * daysPerMonthScale * growthModeScale
    local annualSupTypeProfitCap = EconomyManager.getPriceMultiplier() * annualProductDemand
    if demandIncrease > 0 then
        for index, fillType in pairs(g_fillTypeManager.fillTypes) do
            fillType.factor = math.min(fillType.factor + demandIncrease, demandAccumulationCap)
        end

        for index, subType in pairs(g_currentMission.animalSystem.subTypes) do
            subType.factor = math.min(subType.factor + demandIncrease, demandAccumulationCap)
        end
    end

    for index, fillType in pairs(g_fillTypeManager.fillTypes) do
        if fillType.recentSold > 0 then
            if fillType.graceHours > 0 then
                fillType.graceHours = fillType.graceHours - 1
            else
                local demandDecrease = (fillType.recentSold * fillType.pricePerLiter) / annualProductDemand
                fillType.factor = math.max(fillType.factor - demandDecrease, 0)
                fillType.recentSold = 0
            end
        end
    end

    for index, subType in pairs(g_currentMission.animalSystem.subTypes) do
        if subType.recentSold > 0 then
            if subType.graceHours > 0 then
                subType.graceHours = subType.graceHours - 1
            else
                local demandDecrease = subType.recentSold / annualSupTypeProfitCap
                subType.factor = math.max(subType.factor - demandDecrease, 0)
                subType.recentSold = 0
            end
        end
    end

    broadcastFactors()
end

local function setFillTypeDemandTitles()
    for index, fillType in pairs(g_fillTypeManager.fillTypes) do
        if not fillType.factor then
            populateMissingDataPoints()
        end

        fillType.defaultTitle = fillType.title
        fillType.title = string.format('%s (%d%%)', fillType.title, clampFactor(fillType.factor)*100)
    end
end

local function setFillTypeDefaultTitles()
    for index, fillType in pairs(g_fillTypeManager.fillTypes) do
        if not fillType.factor then
            populateMissingDataPoints()
        end

        fillType.title = fillType.defaultTitle or fillType.title
    end
end

function SupplyAndDemand:loadMap()
    loadXML()
    InGameMenuStatisticsFrame.rebuildTable = Utils.prependedFunction(InGameMenuStatisticsFrame.rebuildTable, setFillTypeDemandTitles)
    InGameMenuStatisticsFrame.onFrameClose = Utils.prependedFunction(InGameMenuStatisticsFrame.onFrameClose, setFillTypeDefaultTitles)
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, hourlyUpdate, SupplyAndDemand)
    SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(SellingStation.getEffectiveFillTypePrice, repriceFillType)
    SellingStation.sellFillType = Utils.appendedFunction(SellingStation.sellFillType, catchFillTypeSale)
    AnimalSellEvent.run = Utils.overwrittenFunction(AnimalSellEvent.run, catchSubTypeSale)
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, saveXML)
end

function SupplyAndDemand:deleteMap()
    g_messageCenter:unsubscribeAll(SupplyAndDemand)
    removeModEventListener(SupplyAndDemand)
end

function SupplyAndDemand:onClientJoined()
    if not g_currentMission:getIsServer() then
        return
    end

    broadcastFactors()
end

addModEventListener(SupplyAndDemand)