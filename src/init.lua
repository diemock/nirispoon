local wf = hs.window.filter
local win = hs.window
local screen = hs.screen
local alert = hs.alert
local timer = hs.timer
local hotkey = hs.hotkey

--==============================================================================
-- КОНФИГУРАЦИЯ
--==============================================================================
local Config = {
    -- Основные настройки
    minColumns = 1,
    maxColumns = 8,
    defaultColumns = 3,
    focusedWeight = 1.6,
    weightStep = 0.2,
    minFocusedWeight = 1.0,
    singleColumnWidth = 0.5, -- ширина одной колонки по центру (50%)

    -- Вертикальное расположение
    verticalGap = 10,   -- зазор между окнами в колонке (10px)
    horizontalGap = 10, -- зазор между колонками (10px)

    -- Распределение окон в колонке
    verticalSplitRatios = {             -- соотношения для разного кол-ва окон в колонке
        [1] = { 1.0 },                  -- одно окно: 100%
        [2] = { 0.5, 0.5 },             -- два окна: 50%/50%
        [3] = { 0.4, 0.3, 0.3 },        -- три окна: 40%/30%/30%
        [4] = { 0.35, 0.25, 0.2, 0.2 }, -- и т.д.
    },

    -- Внешний вид
    offscreenX = 15000, -- сдвиг для скрытых окон

    -- Поведение
    newWindowDelay = 0.12, -- задержка добавления нового окна (сек)

    -- Keycodes (ANSI/US layout) для стабильности в любой раскладке
    Keycodes = {
        H = 4,
        L = 37,
        J = 38,
        K = 40, -- H J K L
        F = 3,
        R = 15,
        SLASH = 44, -- F R /
        COMMA = 43,
        DOT = 47,   -- , .
        U = 32,
        I = 34,     -- U I (вместо [ ])
        W = 13,     -- W для увеличения ширины
        S = 1,      -- S для уменьшения ширины
        V = 9,
        B = 11,     -- V B (вертикальное управление)
        M = 46,
        N = 45,     -- M N для слияния окон
    },

    -- Сочетания клавиш
    Modifiers = {
        primary = { "alt", "shift" },
        move = { "cmd", "alt", "shift" },
        viewport = { "alt", "shift", "ctrl" },
        vertical = { "alt", "shift", "ctrl" },
    },

    -- Исключения (плавающие окна)
    FloatingRules = {
        ["Finder"] = true,
        ["System Settings"] = true,
        ["Системные настройки"] = true,
        ["Calculator"] = true,
        ["Калькулятор"] = true,
        ["Activity Monitor"] = true,
        ["Мониторинг системы"] = true,
        ["Dictionary"] = true,
        ["Словарь"] = true,
    },

    -- Игнорируемые приложения
    IgnoredApps = {
        ["Hammerspoon"] = true,
        ["HazeOver"] = true,
        ["Alfred"] = true,
        ["Raycast"] = true,
    },
}

--==============================================================================
-- КЛАСС КОЛОНКИ (VERTICAL STACK)
--==============================================================================
local Column = {}
Column.__index = Column

function Column.new()
    local self = setmetatable({}, Column)
    self.windows = {}   -- список окон сверху вниз
    self.focusedRow = 1 -- активное окно внутри колонки
    return self
end

-- Добавление окна в колонку
function Column:addWindow(window, position)
    if not window then return false end

    local pos = position or #self.windows + 1
    table.insert(self.windows, pos, window)

    -- Если добавляем не в конец, корректируем focusedRow
    if pos <= self.focusedRow then
        self.focusedRow = self.focusedRow + 1
    end

    return true
end

-- Удаление окна из колонки
function Column:removeWindow(window)
    for i, w in ipairs(self.windows) do
        if w and w:id() == window:id() then
            table.remove(self.windows, i)

            -- Коррекция focusedRow
            if i < self.focusedRow then
                self.focusedRow = self.focusedRow - 1
            elseif i == self.focusedRow then
                self.focusedRow = math.min(self.focusedRow, #self.windows)
            end

            return true
        end
    end
    return false
end

-- Количество окон в колонке
function Column:count()
    return #self.windows
end

-- Фокус внутри колонки
function Column:focusNext()
    if self.focusedRow < #self.windows then
        self.focusedRow = self.focusedRow + 1
        return true
    end
    return false
end

function Column:focusPrev()
    if self.focusedRow > 1 then
        self.focusedRow = self.focusedRow - 1
        return true
    end
    return false
end

-- Перемещение окон внутри колонки
function Column:moveWindowUp(window)
    for i, w in ipairs(self.windows) do
        if w and w:id() == window:id() and i > 1 then
            self.windows[i], self.windows[i - 1] = self.windows[i - 1], self.windows[i]

            if self.focusedRow == i then
                self.focusedRow = i - 1
            elseif self.focusedRow == i - 1 then
                self.focusedRow = i
            end

            return true
        end
    end
    return false
end

function Column:moveWindowDown(window)
    for i, w in ipairs(self.windows) do
        if w and w:id() == window:id() and i < #self.windows then
            self.windows[i], self.windows[i + 1] = self.windows[i + 1], self.windows[i]

            if self.focusedRow == i then
                self.focusedRow = i + 1
            elseif self.focusedRow == i + 1 then
                self.focusedRow = i
            end

            return true
        end
    end
    return false
end

-- Получение активного окна
function Column:getFocusedWindow()
    return self.windows[self.focusedRow]
end

--==============================================================================
-- КЛАСС RIBBON (КОЛОНКИ С ВЕРТИКАЛЬНЫМИ СТЕКАМИ)
--==============================================================================
local Ribbon = {}
Ribbon.__index = Ribbon

function Ribbon.new(scr, config)
    local self = setmetatable({}, Ribbon)

    self.screen = scr
    self.config = config or {}

    -- Состояние ленты
    self.columns = {}      -- список колонок (каждая - объект Column)
    self.floating = {}     -- win:id() -> true
    self.focusedColumn = 1 -- активная колонка
    self.viewportStart = 1
    self.visibleColumns = config.defaultColumns or Config.defaultColumns
    self.hasManualWidth = false -- флаг, что пользователь вручную изменил ширину

    return self
end

-- Проверка, принадлежит ли окно к этому экрану
function Ribbon:belongsToThisScreen(window)
    if not window or not window:screen() then return false end
    return window:screen():id() == self.screen:id()
end

-- Поиск окна во всех колонках
function Ribbon:findWindow(window)
    if not window then return nil, nil end
    local winId = window:id()

    for colIndex, column in ipairs(self.columns) do
        for rowIndex, w in ipairs(column.windows) do
            if w and w:id() == winId then
                return colIndex, rowIndex
            end
        end
    end
    return nil, nil
end

-- Проверка управляемости окна
function Ribbon:isManaged(window)
    if not window then return false end
    if not window:isStandard() then return false end
    if not window:application() then return false end

    local appName = window:application():name()

    -- Проверка игнорируемых приложений
    if Config.IgnoredApps[appName] then return false end

    -- Проверка плавающих окон
    if self.floating[window:id()] then return false end
    if Config.FloatingRules[appName] then return false end

    return true
end

-- Очистка невалидных окон
function Ribbon:clean()
    local changed = false

    for colIndex = #self.columns, 1, -1 do
        local column = self.columns[colIndex]

        for rowIndex = #column.windows, 1, -1 do
            local w = column.windows[rowIndex]
            if not w or not w:isVisible() then
                table.remove(column.windows, rowIndex)
                changed = true
            end
        end

        -- Удаляем пустые колонки
        if #column.windows == 0 then
            table.remove(self.columns, colIndex)
            changed = true
        end
    end

    if changed then
        -- Коррекция индексов
        self.focusedColumn = math.max(1, math.min(self.focusedColumn, #self.columns))

        if #self.columns > 0 then
            local focusedCol = self.columns[self.focusedColumn]
            if focusedCol then
                focusedCol.focusedRow = math.min(focusedCol.focusedRow, #focusedCol.windows)
            end
        end

        self.viewportStart = math.max(1, math.min(self.viewportStart,
            math.max(1, #self.columns - self.visibleColumns + 1)))
    end

    return changed
end

-- Функция clamp для чисел
local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

-- Основной метод компоновки (ИСПРАВЛЕННЫЙ ДЛЯ РЕЖИМА ОДНОЙ КОЛОНКИ)
function Ribbon:layout()
    self:clean()
    local totalColumns = #self.columns
    if totalColumns == 0 then return end

    local scrFrame = self.screen:frame()
    local vGap = Config.verticalGap
    local hGap = Config.horizontalGap

    -- Коррекция индексов
    self.focusedColumn = clamp(self.focusedColumn, 1, totalColumns)
    local maxStart = math.max(1, totalColumns - self.visibleColumns + 1)
    self.viewportStart = clamp(self.viewportStart, 1, maxStart)

    -- Центрирование viewport вокруг фокуса
    if self.focusedColumn < self.viewportStart then
        self.viewportStart = self.focusedColumn
    elseif self.focusedColumn >= self.viewportStart + self.visibleColumns then
        self.viewportStart = self.focusedColumn - self.visibleColumns + 1
    end
    self.viewportStart = clamp(self.viewportStart, 1, maxStart)

    -- Расчет видимых колонок
    local visibleCount = math.min(self.visibleColumns, totalColumns - self.viewportStart + 1)

    -- ОСОБЫЙ СЛУЧАЙ: Режим "Одна колонка" - 50% ширины по центру
    -- Проверяем что: 1) ИЛИ физически одна колонка ИЛИ пользователь выбрал 1 видимую колонку
    --                2) Не было ручного изменения ширины
    if ((totalColumns == 1) or (self.visibleColumns == 1)) and not self.hasManualWidth then
        -- Находим первую непустую колонку в viewport
        local visibleColumn = nil
        for i = self.viewportStart, math.min(self.viewportStart + visibleCount - 1, totalColumns) do
            if self.columns[i] and #self.columns[i].windows > 0 then
                visibleColumn = self.columns[i]
                break
            end
        end

        if visibleColumn and #visibleColumn.windows > 0 then
            local colWidth = scrFrame.w * Config.singleColumnWidth
            local colX = scrFrame.x + (scrFrame.w - colWidth) / 2

            -- Расчет высоты для каждого окна в колонке
            local windowCount = #visibleColumn.windows
            local ratios = Config.verticalSplitRatios[windowCount] or
                { 1.0 / windowCount } -- равномерное распределение по умолчанию

            local totalVGapHeight = vGap * (windowCount - 1)
            local availableHeight = scrFrame.h - totalVGapHeight
            local currentY = scrFrame.y

            for rowIndex, window in ipairs(visibleColumn.windows) do
                if window and window:isVisible() then
                    local height = availableHeight * (ratios[rowIndex] or (1.0 / windowCount))

                    window:setFrame({
                        x = colX,
                        y = currentY,
                        w = colWidth,
                        h = height
                    }, 0)

                    currentY = currentY + height + vGap
                end
            end

            -- Скрываем остальные колонки (если есть)
            for colIndex = 1, totalColumns do
                if colIndex ~= self.viewportStart then
                    local column = self.columns[colIndex]
                    if column then
                        for _, window in ipairs(column.windows) do
                            if window and window:isVisible() then
                                window:setTopLeft({
                                    x = scrFrame.x + scrFrame.w + Config.offscreenX,
                                    y = scrFrame.y
                                })
                            end
                        end
                    end
                end
            end

            -- Фокусировка активного окна
            local focusedWindow = visibleColumn:getFocusedWindow()
            if focusedWindow and focusedWindow:isVisible() then
                pcall(function()
                    focusedWindow:focus()
                end)
            end

            return -- Выходим, т.к. уже расположили колонку
        end
    end

    -- ОБЫЧНЫЙ СЛУЧАЙ: Несколько колонок или пользователь изменил ширину

    -- Расчет весов колонок (фокусная шире)
    local colWeights = {}
    local totalWeight = 0

    for i = 1, visibleCount do
        local colIndex = self.viewportStart + i - 1
        local column = self.columns[colIndex]
        if column then
            local weight = (colIndex == self.focusedColumn) and (self.config.focusedWeight or Config.focusedWeight) or
                1
            colWeights[i] = weight
            totalWeight = totalWeight + weight
        else
            colWeights[i] = 1 -- Если колонка отсутствует, устанавливаем вес по умолчанию
            totalWeight = totalWeight + 1
        end
    end

    if totalWeight == 0 then return end

    -- Расположение колонок
    local currentX = scrFrame.x
    local totalHGapWidth = hGap * (visibleCount - 1)
    local availableWidth = scrFrame.w - totalHGapWidth

    for i = 1, visibleCount do
        local colIndex = self.viewportStart + i - 1
        local column = self.columns[colIndex]

        if column and #column.windows > 0 then
            local colWidth = availableWidth * (colWeights[i] / totalWeight)

            -- Расчет высоты для каждого окна в колонке
            local windowCount = #column.windows
            local ratios = Config.verticalSplitRatios[windowCount] or
                { 1.0 / windowCount } -- равномерное распределение по умолчанию

            local totalVGapHeight = vGap * (windowCount - 1)
            local availableHeight = scrFrame.h - totalVGapHeight
            local currentY = scrFrame.y

            for rowIndex, window in ipairs(column.windows) do
                if window and window:isVisible() then
                    local height = availableHeight * (ratios[rowIndex] or (1.0 / windowCount))

                    window:setFrame({
                        x = currentX,
                        y = currentY,
                        w = colWidth,
                        h = height
                    }, 0)

                    currentY = currentY + height + vGap
                end
            end

            currentX = currentX + colWidth + hGap
        else
            -- Если колонка пустая или отсутствует, пропускаем ее, но учитываем ширину
            if colWeights[i] then
                local colWidth = availableWidth * (colWeights[i] / totalWeight)
                currentX = currentX + colWidth + hGap
            end
        end
    end

    -- Скрытие невидимых колонок
    for colIndex, column in ipairs(self.columns) do
        if colIndex < self.viewportStart or colIndex >= self.viewportStart + visibleCount then
            for _, window in ipairs(column.windows) do
                if window and window:isVisible() then
                    window:setTopLeft({
                        x = scrFrame.x + scrFrame.w + Config.offscreenX,
                        y = scrFrame.y
                    })
                end
            end
        end
    end

    -- Фокусировка активного окна
    local focusedColumn = self.columns[self.focusedColumn]
    if focusedColumn then
        local focusedWindow = focusedColumn:getFocusedWindow()
        if focusedWindow and focusedWindow:isVisible() then
            pcall(function()
                focusedWindow:focus()
            end)
        end
    end
end

-- Добавление окна в ленту (ВСЕГДА СОЗДАЕТ НОВУЮ КОЛОНКУ)
function Ribbon:addWindow(window, options)
    if not window or not self:isManaged(window) then return false end

    local colIndex, rowIndex = self:findWindow(window)
    if colIndex then return false end -- окно уже в ленте

    local opts = options or {}
    local targetCol = opts.column or #self.columns + 1 -- ВСЕГДА НОВАЯ КОЛОНКА

    -- Если указана позиция, вставляем колонку в нужное место
    if opts.insertAt then
        targetCol = opts.insertAt
        table.insert(self.columns, targetCol, Column.new())
    else
        -- Иначе добавляем в конец
        table.insert(self.columns, targetCol, Column.new())
    end

    local column = self.columns[targetCol]

    -- Добавляем окно в указанную позицию
    local targetRow = opts.row or 1
    column:addWindow(window, targetRow)

    -- Устанавливаем фокус на новое окно
    self.focusedColumn = targetCol
    column.focusedRow = 1

    -- Сбрасываем флаг ручной ширины при добавлении нового окна
    self.hasManualWidth = false

    self:layout()
    return true
end

-- Удаление окна из ленты (ИСПРАВЛЕНО ДЛЯ РЕЖИМА ОДНОЙ КОЛОНКИ)
function Ribbon:removeWindow(window)
    local colIndex, rowIndex = self:findWindow(window)
    if not colIndex then return false end

    local column = self.columns[colIndex]
    if column and column:removeWindow(window) then
        -- Если колонка пустая, удаляем ее
        if #column.windows == 0 then
            table.remove(self.columns, colIndex)

            -- Коррекция фокуса
            if self.focusedColumn >= colIndex and self.focusedColumn > 1 then
                self.focusedColumn = self.focusedColumn - 1
            end
        end

        -- Если осталась только одна колонка, сбрасываем флаг ручной ширины
        if #self.columns == 1 then
            self.hasManualWidth = false
        end

        -- Сбрасываем флаг ручной ширины при удалении окна
        -- (но только если это не привело к пустой ленте)
        if #self.columns > 0 then
            self.hasManualWidth = false
        end

        self:layout()
        return true
    end

    return false
end

-- Навигация по горизонтали (между колонками)
function Ribbon:focusNextColumn()
    if self.focusedColumn < #self.columns then
        self.focusedColumn = self.focusedColumn + 1
        self:layout()
    end
end

function Ribbon:focusPrevColumn()
    if self.focusedColumn > 1 then
        self.focusedColumn = self.focusedColumn - 1
        self:layout()
    end
end

-- Навигация по вертикали (внутри колонки)
function Ribbon:focusNextRow()
    local column = self.columns[self.focusedColumn]
    if column and column:focusNext() then
        self:layout()
    end
end

function Ribbon:focusPrevRow()
    local column = self.columns[self.focusedColumn]
    if column and column:focusPrev() then
        self:layout()
    end
end

-- Перемещение активного окна между колонками (ИСПРАВЛЕННЫЙ - ВСЕГДА НОВАЯ КОЛОНКА)
function Ribbon:moveActiveWindowRight()
    local column = self.columns[self.focusedColumn]
    if not column then return end

    local window = column:getFocusedWindow()
    if not window then return end

    -- Удаляем из текущей колонки
    column:removeWindow(window)

    -- Если текущая колонка теперь пустая, удаляем ее
    if #column.windows == 0 then
        table.remove(self.columns, self.focusedColumn)
    end

    -- Определяем позицию для новой колонки (справа от текущей)
    local targetCol = self.focusedColumn + 1
    if targetCol > #self.columns + 1 then
        targetCol = #self.columns + 1
    end

    -- Создаем новую колонку и вставляем окно
    table.insert(self.columns, targetCol, Column.new())
    local newColumn = self.columns[targetCol]

    if newColumn then
        newColumn:addWindow(window, 1)
        newColumn.focusedRow = 1

        -- Обновляем фокус
        self.focusedColumn = targetCol

        -- Сбрасываем флаг ручной ширины при перемещении
        self.hasManualWidth = false

        self:layout()
        alert.show("Окно перемещено вправо", 0.5)
    end
end

function Ribbon:moveActiveWindowLeft()
    local column = self.columns[self.focusedColumn]
    if not column then return end

    local window = column:getFocusedWindow()
    if not window then return end

    -- Удаляем из текущей колонки
    column:removeWindow(window)

    -- Если текущая колонка теперь пустая, удаляем ее
    if #column.windows == 0 then
        table.remove(self.columns, self.focusedColumn)
        self.focusedColumn = math.max(1, self.focusedColumn - 1)
    end

    -- Определяем позицию для новой колонки (слева от текущей)
    local targetCol = math.max(1, self.focusedColumn - 1)

    -- Создаем новую колонку и вставляем окно
    table.insert(self.columns, targetCol, Column.new())
    local newColumn = self.columns[targetCol]

    if newColumn then
        newColumn:addWindow(window, 1)
        newColumn.focusedRow = 1

        -- Обновляем фокус
        self.focusedColumn = targetCol

        -- Сбрасываем флаг ручной ширины при перемещении
        self.hasManualWidth = false

        self:layout()
        alert.show("Окно перемещено влево", 0.5)
    end
end

-- Перемещение активного окна внутри колонки
function Ribbon:moveActiveWindowUp()
    local column = self.columns[self.focusedColumn]
    if column then
        local window = column:getFocusedWindow()
        if window and column:moveWindowUp(window) then
            self:layout()
        end
    end
end

function Ribbon:moveActiveWindowDown()
    local column = self.columns[self.focusedColumn]
    if column then
        local window = column:getFocusedWindow()
        if window and column:moveWindowDown(window) then
            self:layout()
        end
    end
end

-- Специальные операции - слияние окон (Alt+Shift+M/N)
function Ribbon:mergeWindowRight()
    -- Объединить активное окно с окном справа (поместить в одну колонку)
    local column = self.columns[self.focusedColumn]
    if not column then return end

    local window = column:getFocusedWindow()
    if not window then return end

    -- Проверяем, есть ли колонка справа
    if self.focusedColumn >= #self.columns then
        alert.show("Нет колонки справа для слияния", 0.8)
        return
    end

    local rightColumn = self.columns[self.focusedColumn + 1]
    if not rightColumn then return end

    -- Удаляем активное окно из текущей колонки
    column:removeWindow(window)

    -- Если текущая колонка теперь пустая, удаляем ее
    if #column.windows == 0 then
        table.remove(self.columns, self.focusedColumn)
    else
        -- Иначе перемещаем фокус на следующую колонку
        self.focusedColumn = self.focusedColumn + 1
    end

    -- Добавляем окно в правую колонку (в конец)
    rightColumn:addWindow(window)
    rightColumn.focusedRow = #rightColumn.windows

    -- Сбрасываем флаг ручной ширины при слиянии
    self.hasManualWidth = false

    self:layout()
    alert.show("Окно объединено с колонкой справа", 0.8)
end

function Ribbon:mergeWindowLeft()
    -- Объединить активное окно с окном слева (поместить в одну колонку)
    local column = self.columns[self.focusedColumn]
    if not column then return end

    local window = column:getFocusedWindow()
    if not window then return end

    -- Проверяем, есть ли колонка слева
    if self.focusedColumn <= 1 then
        alert.show("Нет колонки слева для слияния", 0.8)
        return
    end

    local leftColumn = self.columns[self.focusedColumn - 1]
    if not leftColumn then return end

    -- Удаляем активное окно из текущей колонки
    column:removeWindow(window)

    -- Если текущая колонка теперь пустая, удаляем ее
    if #column.windows == 0 then
        table.remove(self.columns, self.focusedColumn)
        self.focusedColumn = self.focusedColumn - 1
    end

    -- Добавляем окно в левую колонку (в конец)
    leftColumn:addWindow(window)
    leftColumn.focusedRow = #leftColumn.windows

    -- Фокус остается на левой колонке
    self.focusedColumn = math.max(1, self.focusedColumn - 1)

    -- Сбрасываем флаг ручной ширины при слиянии
    self.hasManualWidth = false

    self:layout()
    alert.show("Окно объединено с колонкой слева", 0.8)
end

-- Изменение ширины фокуса (ТЕПЕРЬ УСТАНАВЛИВАЕТ ФЛАГ РУЧНОЙ ШИРИНЫ)
function Ribbon:changeFocusedWeight(delta)
    -- Устанавливаем флаг, что пользователь вручно изменил ширину
    self.hasManualWidth = true

    self.config.focusedWeight = math.max(Config.minFocusedWeight,
        (self.config.focusedWeight or Config.focusedWeight) + delta)
    self:layout()

    alert.show("Ширина: " .. string.format("%.1f", self.config.focusedWeight), 0.8)
end

-- Изменение количества колонок (ТЕПЕРЬ СБРАСЫВАЕТ ФЛАГ ЕСЛИ ОСТАЛАСЬ ОДНА КОЛОНКА)
function Ribbon:changeVisibleColumns(delta)
    -- Устанавливаем флаг, что пользователь вручно изменил ширину
    self.hasManualWidth = true

    self.visibleColumns = clamp(
        self.visibleColumns + delta,
        Config.minColumns,
        Config.maxColumns
    )

    -- Если установлено 1 видимых колонок, сбрасываем флаг ручной ширины
    if self.visibleColumns == 1 then
        self.hasManualWidth = false
    end

    self:layout()

    alert.show("Видимых колонок: " .. self.visibleColumns, 0.8)
end

-- Прокрутка видимой области
function Ribbon:scrollViewportRight()
    local maxStart = math.max(1, #self.columns - self.visibleColumns + 1)
    self.viewportStart = math.min(self.viewportStart + 1, maxStart)
    self:layout()
end

function Ribbon:scrollViewportLeft()
    self.viewportStart = math.max(1, self.viewportStart - 1)
    self:layout()
end

-- Переключение плавающего режима для активного окна
function Ribbon:toggleFloatingForActiveWindow()
    -- Получаем активное окно
    local activeWindow = win.focusedWindow()
    if not activeWindow then
        alert.show("Нет активного окна", 0.8)
        return
    end

    local winId = activeWindow:id()

    -- Проверяем, управляется ли окно этой лентой
    local colIndex, rowIndex = self:findWindow(activeWindow)
    local isInRibbon = colIndex ~= nil

    if isInRibbon then
        -- Окно в ленте - переводим в плавающий режим
        self.floating[winId] = true

        -- Сохраняем текущую позицию окна
        local currentFrame = activeWindow:frame()
        local screenFrame = self.screen:frame()

        -- Удаляем из ленты
        self:removeWindow(activeWindow)

        -- Немедленно поднимаем окно и фокусируем
        if activeWindow:isVisible() then
            -- Восстанавливаем позицию или устанавливаем новую
            if currentFrame.x < screenFrame.x + screenFrame.w then
                -- Окно было видимым, сохраняем позицию
                activeWindow:setFrame(currentFrame, 0)
            else
                -- Окно было скрыто, показываем в центре
                activeWindow:setFrame({
                    x = screenFrame.x + screenFrame.w * 0.25,
                    y = screenFrame.y + screenFrame.h * 0.25,
                    w = screenFrame.w * 0.5,
                    h = screenFrame.h * 0.5
                }, 0)
            end

            -- Поднимаем и фокусируем
            activeWindow:raise()
            activeWindow:focus()
        end

        alert.show("Окно переведено в плавающий режим", 0.8)
    elseif self.floating[winId] then
        -- Окно уже плавающее - возвращаем в ленту
        self.floating[winId] = nil

        -- Добавляем окно обратно в ленту (в новую колонку)
        if self:addWindow(activeWindow, {}) then
            alert.show("Окно возвращено в ленту", 0.8)
        else
            alert.show("Не удалось вернуть окно в ленту", 0.8)
        end
    else
        -- Окно не управляется этой лентой и не плавающее
        -- Проверяем, принадлежит ли окно этому экрану и управляемо ли оно
        if self:belongsToThisScreen(activeWindow) and self:isManaged(activeWindow) then
            -- Добавляем окно в ленту (в новую колонку)
            if self:addWindow(activeWindow, {}) then
                alert.show("Окно добавлено в ленту", 0.8)
            else
                alert.show("Не удалось добавить окно в ленту", 0.8)
            end
        else
            alert.show("Окно не может быть управляемо лентой", 0.8)
        end
    end
end

-- Специальные операции с колонками
function Ribbon:splitColumn()
    -- Разделить текущую колонку на две (по горизонтали)
    local column = self.columns[self.focusedColumn]
    if not column or #column.windows < 2 then return end

    -- Создаем новую колонку справа
    table.insert(self.columns, self.focusedColumn + 1, Column.new())
    local newColumn = self.columns[self.focusedColumn + 1]

    -- Переносим половину окон в новую колонку
    local midIndex = math.floor(#column.windows / 2) + 1

    for i = midIndex, #column.windows do
        local window = column.windows[midIndex] -- индекс смещается при удалении
        if window then
            column:removeWindow(window)
            newColumn:addWindow(window)
        end
    end

    self.focusedColumn = self.focusedColumn + 1

    -- Устанавливаем флаг ручной ширины при разделении
    self.hasManualWidth = true

    self:layout()
    alert.show("Колонка разделена", 0.8)
end

function Ribbon:mergeColumnRight()
    -- Объединить с колонкой справа
    if self.focusedColumn >= #self.columns then return end

    local column = self.columns[self.focusedColumn]
    local rightColumn = self.columns[self.focusedColumn + 1]

    if not column or not rightColumn then return end

    -- Перемещаем все окна из правой колонки
    while #rightColumn.windows > 0 do
        local window = rightColumn.windows[1]
        if window then
            rightColumn:removeWindow(window)
            column:addWindow(window)
        end
    end

    -- Удаляем пустую правую колонку
    table.remove(self.columns, self.focusedColumn + 1)

    -- Устанавливаем флаг ручной ширины при слиянии
    self.hasManualWidth = true

    self:layout()
    alert.show("Колонки объединены", 0.8)
end

-- Сбор всех окон на экране (ВСЕГДА ОТДЕЛЬНАЯ КОЛОНКА НА КАЖДОЕ ОКНО)
function Ribbon:collectWindows()
    self.columns = {}

    local windowsToAdd = {}

    -- Собираем все управляемые окна
    for _, w in ipairs(win.orderedWindows()) do
        if self:belongsToThisScreen(w) and self:isManaged(w) and w:isVisible() then
            table.insert(windowsToAdd, w)
        end
    end

    -- Если нет окон, просто сбрасываем состояние
    if #windowsToAdd == 0 then
        self.focusedColumn = 1
        self.viewportStart = 1
        self.hasManualWidth = false
        self:layout()
        return 0
    end

    -- Создаем колонки - ОДНА КОЛОНКА НА КАЖДОЕ ОКНО
    for i = 1, #windowsToAdd do
        table.insert(self.columns, Column.new())
    end

    -- Заполняем каждую колонку ОДНИМ окном
    for i, window in ipairs(windowsToAdd) do
        local column = self.columns[i]
        if column then
            column:addWindow(window)
        end
    end

    -- Сбрасываем флаг ручной ширины при сборе окон
    self.hasManualWidth = false

    -- Ограничиваем количество видимых колонок
    if #self.columns > self.visibleColumns then
        -- Скрываем лишние окна за экраном
        for i = self.visibleColumns + 1, #self.columns do
            local column = self.columns[i]
            if column and #column.windows > 0 then
                local window = column.windows[1]
                if window and window:isVisible() then
                    local scrFrame = self.screen:frame()
                    window:setTopLeft({
                        x = scrFrame.x + scrFrame.w + Config.offscreenX,
                        y = scrFrame.y
                    })
                end
            end
        end
    end

    -- Устанавливаем фокус на первую колонку и первое окно
    self.focusedColumn = 1
    if #self.columns > 0 and self.columns[1] then
        self.columns[1].focusedRow = 1
    end

    self.viewportStart = 1
    self:layout()

    return #windowsToAdd
end

--==============================================================================
-- МЕНЕДЖЕР ЛЕНТ (УПРАВЛЕНИЕ ВСЕМИ ЭКРАНАМИ)
--==============================================================================
local RibbonManager = {
    ribbons = {},       -- screen:id() -> Ribbon
    activeScreen = nil, -- текущий активный экран
}

function RibbonManager:getRibbonForScreen(scr)
    if not scr then return nil end
    local screenId = scr:id()

    if not self.ribbons[screenId] then
        self.ribbons[screenId] = Ribbon.new(scr, {
            focusedWeight = Config.focusedWeight,
        })
    end

    return self.ribbons[screenId]
end

function RibbonManager:getRibbonForWindow(window)
    if not window then return nil end
    local scr = window:screen()
    return scr and self:getRibbonForScreen(scr) or nil
end

function RibbonManager:getActiveRibbon()
    -- Определяем активный экран по фокусу
    local focusedWindow = win.focusedWindow()
    local activeScreen

    if focusedWindow and focusedWindow:screen() then
        activeScreen = focusedWindow:screen()
    else
        activeScreen = screen.mainScreen()
    end

    self.activeScreen = activeScreen
    return self:getRibbonForScreen(activeScreen)
end

function RibbonManager:addWindow(window)
    local ribbon = self:getRibbonForWindow(window)
    if ribbon then
        return ribbon:addWindow(window, {})
    end
    return false
end

function RibbonManager:removeWindow(window)
    for _, ribbon in pairs(self.ribbons) do
        if ribbon:removeWindow(window) then
            return true
        end
    end
    return false
end

function RibbonManager:layoutAll()
    for _, ribbon in pairs(self.ribbons) do
        ribbon:layout()
    end
end

function RibbonManager:collectAllWindows()
    local totalWindows = 0
    for _, ribbon in pairs(self.ribbons) do
        totalWindows = totalWindows + ribbon:collectWindows()
    end
    alert.show("Все окна собраны (" .. totalWindows .. " окон)", 1.0)
end

--==============================================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
--==============================================================================
local function showHelp()
    alert.show([[
--- Ribbon WM (Alt+Shift) ---

ГОРИЗОНТАЛЬНАЯ НАВИГАЦИЯ:
Alt+Shift+H/L      : Фокус влево/вправо (между колонками)
Alt+Shift+,/.      : Уменьшить/увеличить видимые колонки
Alt+Shift+U/I      : Прокрутка видимой области

ВЕРТИКАЛЬНАЯ НАВИГАЦИЯ:
Alt+Shift+J/K      : Фокус вверх/вниз (внутри колонки)
Ctrl+Alt+Shift+J/K : Переместить окно вверх/вниз в колонке

ПЕРЕМЕЩЕНИЕ ОКОН (ВСЕГДА НОВАЯ КОЛОНКА):
Cmd+Alt+Shift+H/L  : Переместить активное окно влево/вправо (новая колонка)

СЛИЯНИЕ ОКОН (ТОЛЬКО ПО ХОТКЕЯМ):
Alt+Shift+M/N      : Объединить окно с колонкой слева/справа

УПРАВЛЕНИЕ ОКНАМИ:
Alt+Shift+F        : Вкл/выкл плавающий режим для активного окна
Alt+Shift+R        : Собрать все окна на всех экранах

ИЗМЕНЕНИЕ ШИРИНЫ:
Alt+Shift+W/S      : Увеличить/уменьшить ширину активной колонки

ПРИМЕЧАНИЕ:
• Одна колонка автоматически центрируется и занимает 50% ширины
  (работает как при физически одной колонке, так и при режиме "Одна колонка")
• Изменение ширины (W/S) или количества колонок переключает в обычный режим
• При удалении окон до одной колонки автоматически включается режим 50%
    ]], 10)
end

--==============================================================================
-- ИНИЦИАЛИЗАЦИЯ И СОБЫТИЯ
--==============================================================================
local function initialize()
    -- Создаем ленты для всех экранов
    for _, scr in ipairs(screen.allScreens()) do
        RibbonManager:getRibbonForScreen(scr)
    end

    -- Собираем все существующие окна
    timer.doAfter(0.5, function()
        RibbonManager:collectAllWindows()
    end)

    -- Показываем справку
    timer.doAfter(1.0, showHelp)

    print("Ribbon WM v3 инициализирован. Экранов: " .. #screen.allScreens())
end

-- Обработчики событий окон
local windowFilter = wf.new()
    :setDefaultFilter()
    :subscribe(wf.windowCreated, function(window)
        timer.doAfter(Config.newWindowDelay, function()
            RibbonManager:addWindow(window)
        end)
    end)
    :subscribe(wf.windowDestroyed, function(window)
        RibbonManager:removeWindow(window)
    end)

--==============================================================================
-- ГОРЯЧИЕ КЛАВИШИ
--==============================================================================
local KC = Config.Keycodes
local Mod = Config.Modifiers

-- Горизонтальная навигация (между колонками)
hotkey.bind(Mod.primary, KC.L, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:focusNextColumn() end
end)

hotkey.bind(Mod.primary, KC.H, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:focusPrevColumn() end
end)

-- Вертикальная навигация (внутри колонки)
hotkey.bind(Mod.primary, KC.K, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:focusPrevRow() end
end)

hotkey.bind(Mod.primary, KC.J, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:focusNextRow() end
end)

-- Горизонтальное перемещение АКТИВНОГО окна (ВСЕГДА НОВАЯ КОЛОНКА)
hotkey.bind(Mod.move, KC.L, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:moveActiveWindowRight() end
end)

hotkey.bind(Mod.move, KC.H, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:moveActiveWindowLeft() end
end)

-- Слияние окон (ТОЛЬКО ПО ХОТКЕЯМ)
hotkey.bind(Mod.primary, KC.M, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:mergeWindowLeft() end
end)

hotkey.bind(Mod.primary, KC.N, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:mergeWindowRight() end
end)

-- Вертикальное перемещение АКТИВНОГО окна внутри колонки
hotkey.bind({ "ctrl", "alt", "shift" }, KC.K, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:moveActiveWindowUp() end
end)

hotkey.bind({ "ctrl", "alt", "shift" }, KC.J, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:moveActiveWindowDown() end
end)

-- Изменение количества колонок
hotkey.bind(Mod.primary, KC.COMMA, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then
        ribbon:changeVisibleColumns(-1)
    end
end)

hotkey.bind(Mod.primary, KC.DOT, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then
        ribbon:changeVisibleColumns(1)
    end
end)

-- Прокрутка видимой области
hotkey.bind(Mod.primary, KC.I, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:scrollViewportRight() end
end)

hotkey.bind(Mod.primary, KC.U, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then ribbon:scrollViewportLeft() end
end)

-- Изменение ширины колонки (W/S вместо Up/Down)
hotkey.bind(Mod.primary, KC.W, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then
        ribbon:changeFocusedWeight(Config.weightStep)
    end
end)

hotkey.bind(Mod.primary, KC.S, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then
        ribbon:changeFocusedWeight(-Config.weightStep)
    end
end)

-- Управление плавающим режимом для АКТИВНОГО окна
hotkey.bind(Mod.primary, KC.F, function()
    -- Получаем активное окно
    local activeWindow = win.focusedWindow()
    if not activeWindow then
        alert.show("Нет активного окна", 0.8)
        return
    end

    -- Получаем ленту для активного окна
    local ribbon = RibbonManager:getRibbonForWindow(activeWindow)
    if not ribbon then
        alert.show("Окно не принадлежит ни одному экрану", 0.8)
        return
    end

    -- Используем новый исправленный метод
    ribbon:toggleFloatingForActiveWindow()
end)

-- Сбор окон
hotkey.bind(Mod.primary, KC.R, function()
    RibbonManager:collectAllWindows()
end)

-- Справка
hotkey.bind(Mod.primary, KC.SLASH, showHelp)

-- Принудительный релоад ленты на активном экране
hotkey.bind({ "ctrl", "alt", "shift" }, KC.R, function()
    local ribbon = RibbonManager:getActiveRibbon()
    if ribbon then
        ribbon:collectWindows()
        alert.show("Лента обновлена", 0.8)
    end
end)

--==============================================================================
-- ЗАПУСК
--==============================================================================
initialize()

-- Возвращаем публичный API для отладки
return {
    RibbonManager = RibbonManager,
    Config = Config,
    showHelp = showHelp,
    reload = function()
        hs.reload()
    end
}
