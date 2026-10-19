import QtQuick
import QtQuick.Layouts
import "../../core"
import "../../core/GoLimits.js" as Limits
import "../../ui"

// Страница «OpenCode» панели. Данные и правки — всё локально.
// «Лимиты»: расход OpenCode Go по окнам 5ч/7д/30д из core/GoUsage
// (лимит — месячные $ на каждую модель; 5ч = 20% мес, неделя = 50%,
// месяц = rolling 30д; Go Plus = ×2). «Настройки»: модель оркестратора
// (opencode.json + live-API), модели субагентов (agents/*.md / inline).
// План задаётся локально, конфигурация моделей — через scripts/opencode-ctl.py.
ColumnLayout {
    id: page

    property var win: null

    visible: win !== null && win.mode === "panel" && win.page === "opencode"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    property string tab: "limits"

    // выбор модели/варианта для карточек настроек
    property string pickModel: ""
    property string pickVariant: ""     // "" | low | high | max
    property string pickAgent: "general"
    property string ctlStatus: ""
    property bool ctlFailed: false

    // "opencode-go/<id>[#variant]" текущего выбора
    readonly property string pickRef: page.pickModel === ""
        ? "" : Limits.GO_PROVIDER + "/" + page.pickModel
                + (page.pickVariant === "" ? "" : "#" + page.pickVariant)

    // «provider/id[#variant]» → "<id>#<variant>"-пара для выбора
    function splitRef(ref) {
        if (!ref || ref === "")
            return ["", ""];
        const i = ref.indexOf("/");
        let id = i >= 0 ? ref.slice(i + 1) : ref;
        const h = id.indexOf("#");
        if (h >= 0)
            return [id.slice(0, h), id.slice(h + 1)];
        return [id, ""];
    }

    function _agentSource(name) {
        const md = GoUsage.agentModels[name];
        if (md !== undefined && md !== "")
            return "agents/" + name + ".md";
        if (GoUsage.inlineAgents[name] !== undefined)
            return "opencode.json (inline)";
        return "нет переопределения";
    }

    function _chooseModel(ref) {
        const p = page.splitRef(ref);
        page.pickModel = p[0];
        page.pickVariant = p[1];
    }

    // общий статус запусков ctl
    function _ctlDone(out, isErr) {
        page.ctlFailed = isErr;
        page.ctlStatus = out.trim() !== "" ? out.trim()
            : (isErr ? "ошибка" : "готово");
    }

    Tabs {
        Layout.fillWidth: true
        options: [
            { "key": "limits", "label": "Лимиты", "icon": "bolt" },
            { "key": "settings", "label": "Настройки", "icon": "settings" }
        ]
        current: page.tab
        onPicked: (key) => page.tab = key
    }

    Loader {
        sourceComponent: page.tab === "limits" ? limitsTab : settingsTab
    }

    /* ── вкладка «Лимиты» ─────────────────────────────────────────────── */

    Component {
        id: limitsTab

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(10)

            // шапка: план, до сброса, обновлено, refresh
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(8)

                Rectangle {
                    implicitHeight: Theme.dp(26)
                    implicitWidth: planRow.implicitWidth + Theme.dp(16)
                    radius: Theme.radiusPill
                    color: Theme.accentContainer

                    Row {
                        id: planRow
                        anchors.centerIn: parent
                        spacing: Theme.dp(5)

                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "bolt"
                            size: Theme.dp(14)
                            color: Theme.fgAccentContainer
                        }

                        LText {
                            anchors.verticalCenter: parent.verticalCenter
                            role: "labelMedium"
                            color: Theme.fgAccentContainer
                            text: "OpenCode " + GoUsage.planLabel
                        }
                    }
                }

                LText {
                    Layout.alignment: Qt.AlignVCenter
                    role: "labelMedium"
                    color: Theme.subtext
                    text: "до сброса " + GoUsage.renewDays + " дн."
                }

                Item { Layout.fillWidth: true }

                LText {
                    visible: GoUsage.ready
                    Layout.alignment: Qt.AlignVCenter
                    role: "labelSmall"
                    color: Theme.subtextDim
                    text: GoUsage.busy
                        ? "обновление…"
                        : "обновлено " + Qt.formatDateTime(GoUsage.updatedAt, "HH:mm")
                }

                IconButton {
                    icon: "refresh"
                    disabled: GoUsage.busy
                    onClicked: GoUsage.refresh()
                }
            }

            // ошибка БД
            LText {
                visible: GoUsage.error
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.fgErrorContainer
                wrapMode: Text.WordWrap
                text: GoUsage.errorText
            }

            // ── Общий расход по подписке OpenCode Go ──────────────────────
            Card {
                id: subCard

                visible: GoUsage.ready && !GoUsage.error
                Layout.fillWidth: true

                readonly property var agg: GoUsage.aggregate
                readonly property string tone: GoUsage.toneKey(subCard.agg ? subCard.agg.worstPct : 0)
                readonly property color ink: subCard.tone === "error" ? Theme.error
                    : subCard.tone === "warn" ? Theme.warning : Theme.primary

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(6)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(8)

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            LText {
                                Layout.fillWidth: true
                                role: "titleSmall"
                                weight: 620
                                color: Theme.text
                                elide: Text.ElideRight
                                text: "Подписка OpenCode " + GoUsage.planLabel
                            }

                            LText {
                                Layout.fillWidth: true
                                role: "labelSmall"
                                color: Theme.subtextDim
                                elide: Text.ElideRight
                                text: "общий расход по всем моделям opencode-go"
                            }
                        }

                        LText {
                            Layout.alignment: Qt.AlignVCenter
                            role: "titleMedium"
                            tabular: true
                            color: subCard.ink
                            text: Math.round(subCard.agg ? subCard.agg.worstPct : 0) + "%"
                        }
                    }

                    UsageRow {
                        label: GoUsage.windowTitle("5h")
                        spent: subCard.agg ? subCard.agg.spent5 : 0
                        cap: subCard.agg ? subCard.agg.cap5 : GoUsage.planWindowCap("5h")
                        pct: subCard.agg ? subCard.agg.pct5 : 0
                        Layout.fillWidth: true
                    }
                    UsageRow {
                        label: GoUsage.windowTitle("7d")
                        spent: subCard.agg ? subCard.agg.spent7 : 0
                        cap: subCard.agg ? subCard.agg.cap7 : GoUsage.planWindowCap("7d")
                        pct: subCard.agg ? subCard.agg.pct7 : 0
                        Layout.fillWidth: true
                    }
                    UsageRow {
                        label: GoUsage.windowTitle("30d")
                        spent: subCard.agg ? subCard.agg.spent30 : 0
                        cap: subCard.agg ? subCard.agg.cap30 : GoUsage.planWindowCap("30d")
                        pct: subCard.agg ? subCard.agg.pct30 : 0
                        Layout.fillWidth: true
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(8)

                        LText {
                            role: "labelSmall"
                            color: Theme.subtext
                            text: "запросов 5ч " + (subCard.agg ? subCard.agg.req5 : 0)
                                  + " · 7д " + (subCard.agg ? subCard.agg.req7 : 0)
                                  + " · 30д " + (subCard.agg ? subCard.agg.req30 : 0)
                        }

                        Item { Layout.fillWidth: true }

                        LText {
                            role: "labelSmall"
                            color: Theme.subtextDim
                            text: "моделей: " + GoUsage.models.length
                        }
                    }
                }
            }

            // пустой месяц: трат нет вовсе
            LText {
                visible: GoUsage.ready && !GoUsage.error
                         && GoUsage.models.length === 0 && GoUsage.freeModels.length === 0
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.subtext
                text: "За 30 дней трат opencode-go не было."
            }

            // Заголовок разбивки по моделям
            LText {
                visible: GoUsage.models.length > 0
                Layout.fillWidth: true
                role: "labelMedium"
                color: Theme.subtext
                text: "Разбивка по моделям"
            }

            // Максимум информации по каждой лимитированной модели, худшие сверху
            Repeater {
                model: GoUsage.models

                delegate: Card {
                    id: modelCard

                    required property var modelData

                    Layout.fillWidth: true

                    readonly property string tone: GoUsage.toneKey(modelData.worstPct)
                    readonly property color ink: modelCard.tone === "error" ? Theme.error
                        : modelCard.tone === "warn" ? Theme.warning : Theme.primary

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        RowLayout { // имя (raw id мелким) + худший % окна
                            Layout.fillWidth: true
                            spacing: Theme.dp(8)

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                LText {
                                    Layout.fillWidth: true
                                    role: "titleSmall"
                                    weight: 620
                                    color: Theme.text
                                    elide: Text.ElideRight
                                    text: modelData.name
                                }

                                LText {
                                    Layout.fillWidth: true
                                    role: "labelSmall"
                                    color: Theme.subtextDim
                                    elide: Text.ElideRight
                                    text: modelData.id
                                }
                            }

                            LText {
                                Layout.alignment: Qt.AlignVCenter
                                role: "titleMedium"
                                tabular: true
                                color: modelCard.ink
                                text: Math.round(modelData.worstPct) + "%"
                            }
                        }

                        UsageRow { label: GoUsage.windowLabel("5h"); spent: modelData.spent5; cap: GoUsage.windowCap(modelData, "5h"); pct: modelData.pct5; Layout.fillWidth: true }
                        UsageRow { label: GoUsage.windowLabel("7d"); spent: modelData.spent7; cap: GoUsage.windowCap(modelData, "7d"); pct: modelData.pct7; Layout.fillWidth: true }
                        UsageRow { label: GoUsage.windowLabel("30d"); spent: modelData.spent30; cap: GoUsage.windowCap(modelData, "30d"); pct: modelData.pct30; Layout.fillWidth: true }

                        RowLayout { // запросы по окнам + последнее использование
                            Layout.fillWidth: true
                            spacing: Theme.dp(8)

                            LText {
                                role: "labelSmall"
                                color: Theme.subtext
                                text: "запросов 5ч " + modelData.req5
                                      + " · 7д " + modelData.req7
                                      + " · 30д " + modelData.req30
                            }

                            Item { Layout.fillWidth: true }

                            LText {
                                role: "labelSmall"
                                color: Theme.subtextDim
                                text: "была " + modelData.lastLabel
                            }
                        }
                    }
                }
            }

            // unlimited (free) модели с тратами — компактно
            Card {
                visible: GoUsage.freeModels.length > 0
                Layout.fillWidth: true
                title: "Unlimited"

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(4)

                    Repeater {
                        model: GoUsage.freeModels

                        delegate: RowLayout {
                            required property var modelData

                            Layout.fillWidth: true
                            spacing: Theme.dp(8)

                            LText {
                                Layout.fillWidth: true
                                role: "bodyMedium"
                                color: Theme.text
                                elide: Text.ElideRight
                                text: modelData.name + " · " + modelData.id
                            }

                            LText {
                                Layout.alignment: Qt.AlignVCenter
                                role: "labelSmall"
                                tabular: true
                                color: Theme.subtext
                                text: modelData.req30 + " запр."
                            }

                            LText {
                                Layout.alignment: Qt.AlignVCenter
                                role: "labelSmall"
                                color: Theme.subtextDim
                                text: modelData.lastLabel
                            }
                        }
                    }
                }
            }

            // в Go-таблице, но не тратилась — компактный ряд чипов
            Card {
                visible: GoUsage.unusedModels.length > 0
                Layout.fillWidth: true
                title: "Не тратилась"

                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.dp(6)

                    Repeater {
                        model: GoUsage.unusedModels

                        delegate: Chip {
                            required property string modelData

                            kind: "assist"
                            label: Limits.nameOf(modelData)
                        }
                    }
                }
            }
        }
    }

    /* ── строка одного окна в карточке модели ────────────────────────── */

    component UsageRow: RowLayout {
        id: ur

        // подпись окна и данные уже посчитаны снаружи — так биндингу не по
        // каким dynamic-ключам var-объекта ходить (на них QML ругался
        // «Unable to assign [undefined] to double»)
        property string label: "5ч"
        property real spent: 0
        property real cap: 0
        property real pct: 0

        readonly property string tone: GoUsage.toneKey(pct)
        readonly property color ink: ur.tone === "error" ? Theme.error
            : ur.tone === "warn" ? Theme.warning : Theme.primary

        spacing: Theme.dp(6)

        LText {
            Layout.alignment: Qt.AlignVCenter
            Layout.minimumWidth: Theme.dp(26)
            role: "labelMedium"
            color: Theme.subtext
            text: ur.label
        }

        LText {
            Layout.alignment: Qt.AlignVCenter
            role: "labelMedium"
            tabular: true
            color: Theme.text
            text: GoUsage.money(ur.spent) + " из " + GoUsage.money(ur.cap)
        }

        LinearProgress {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            wavy: ur.tone === "warn" || ur.tone === "error"
            value: ur.pct / 100
            color: ur.ink
        }

        LText {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Theme.dp(38)
            role: "labelMedium"
            tabular: true
            color: ur.ink
            horizontalAlignment: Text.AlignRight
            text: Math.round(ur.pct) + "%"
        }
    }

    /* ── переиспользуемые рода чипов для вкладки «Настройки» ──────────── */

    // чипы выбора модели (лимитированные: больше $ — раньше)
    component ModelChips: Flow {
        id: mc

        property string selected: ""
        signal picked(string modelId)

        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Repeater {
            model: {
                const ids = Object.keys(Limits.GO_LIMITS);
                ids.sort((a, b) => Limits.GO_LIMITS[b] - Limits.GO_LIMITS[a]);
                return ids;
            }

            delegate: Chip {
                required property string modelData

                text: Limits.nameOf(modelData)
                selected: mc.selected === modelData
                onClicked: mc.picked(modelData)
            }
        }
    }

    // чипы варианта reasoning-модели: «без» + варианты
    component VariantChips: Flow {
        id: vc

        property string selected: ""
        signal picked(string variant)

        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Repeater {
            model: [
                { "key": "", "label": "без варианта" },
                { "key": "low", "label": "low" },
                { "key": "high", "label": "high" },
                { "key": "max", "label": "max" }
            ]

            delegate: Chip {
                required property var modelData

                text: modelData.label
                selected: vc.selected === modelData.key
                onClicked: vc.picked(modelData.key)
            }
        }
    }

    /* ── вкладка «Настройки» ─────────────────────────────────────────── */

    Component {
        id: settingsTab

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(10)

            // ── оркестратор: модель по умолчанию ───────────────────────
            Card {
                Layout.fillWidth: true
                title: "Оркестратор"

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(8)

                    LText {
                        Layout.fillWidth: true
                        role: "labelMedium"
                        color: Theme.subtext
                        elide: Text.ElideRight
                        text: "сейчас: " + (GoUsage.defaultModelRef || "— ключа model в opencode.json нет —")
                    }

                    LText {
                        Layout.fillWidth: true
                        visible: page.pickModel === ""
                        role: "bodySmall"
                        color: Theme.subtextDim
                        text: "выбери модель и вариант — кнопки ниже применят выбор"
                    }

                    ModelChips {
                        selected: page.pickModel
                        onPicked: (id) => page.pickModel = id
                    }

                    VariantChips {
                        selected: page.pickVariant
                        onPicked: (v) => page.pickVariant = v
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(8)

                        Button {
                            text: "По умолчанию"
                            variant: "tonal"
                            disabled: GoUsage.ctlBusy
                            onClicked: GoUsage.runCtl(["main-model", "default"], page._ctlDone)
                        }

                        Button {
                            text: "Сейчас (live)"
                            disabled: page.pickModel === "" || GoUsage.ctlBusy
                            onClicked: GoUsage.runCtl(["main-model", page.pickRef, "--live"], page._ctlDone)
                        }

                        Item { Layout.fillWidth: true }
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "bodySmall"
                        color: Theme.subtextDim
                        wrapMode: Text.WordWrap
                        text: "«По умолчанию» пишет opencode.json и делает reload; «Сейчас» переключает активную сессию оркестратора через API сервера."
                    }
                }
            }

            // ── субагенты: general/explore/scout/tester/reviewer ────────
            Card {
                Layout.fillWidth: true
                title: "Субагенты"

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(8)

                    Flow {
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Repeater {
                            model: GoUsage.agentList

                            delegate: Chip {
                                required property string modelData

                                text: modelData
                                selected: page.pickAgent === modelData
                                onClicked: {
                                    page.pickAgent = modelData;
                                    page._chooseModel(GoUsage.agentCurrent(modelData));
                                }
                            }
                        }
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "labelMedium"
                        color: Theme.subtext
                        elide: Text.ElideRight
                        text: page.pickAgent + ": "
                              + (GoUsage.agentCurrent(page.pickAgent) || "по умолчанию оркестратора")
                              + " · " + page._agentSource(page.pickAgent)
                    }

                    ModelChips {
                        selected: page.pickModel
                        onPicked: (id) => page.pickModel = id
                    }

                    VariantChips {
                        selected: page.pickVariant
                        onPicked: (v) => page.pickVariant = v
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(8)

                        Button {
                            text: "Применить"
                            disabled: page.pickModel === "" || GoUsage.ctlBusy
                            onClicked: GoUsage.runCtl(["agent-model", page.pickAgent, page.pickRef], page._ctlDone)
                        }

                        Item { Layout.fillWidth: true }
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "bodySmall"
                        color: Theme.subtextDim
                        wrapMode: Text.WordWrap
                        text: "Пишется agents/<имя>.md (frontmatter model:), а для general/explore — inline-агенты opencode.json; затем reload."
                    }
                }
            }

            // ── план Go / Go Plus ────────────────────────────────────────
            Card {
                Layout.fillWidth: true
                title: "План"

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(8)

                    RowLayout {
                        spacing: Theme.dp(6)

                        Chip {
                            text: "Go"
                            selected: Prefs.goPlan === "go"
                            onClicked: Prefs.set("goPlan", "go")
                        }

                        Chip {
                            text: "Go Plus"
                            selected: Prefs.goPlan === "plus"
                            onClicked: Prefs.set("goPlan", "plus")
                        }

                        Item { Layout.fillWidth: true }
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "bodySmall"
                        color: Theme.subtextDim
                        wrapMode: Text.WordWrap
                        text: "Все платные модели подписки делят единый нормализованный счётчик. Окна: 5ч = 20% месяца, неделя = 50%, месяц = 100%. Go Plus увеличивает квоту до $240/мес."
                    }
                }
            }

            // ── порог предупреждения в лимитах ────────────────────────
            Card {
                Layout.fillWidth: true
                title: "Порог предупреждения"

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(8)

                    Slider {
                        Layout.fillWidth: true
                        size: "s"
                        from: 0
                        to: 100
                        stepSize: 1
                        value: Prefs.goWarnPct
                        valueText: (v) => Math.round(v) + "%"
                        onCommitted: (v) => Prefs.set("goWarnPct", Math.round(v))
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "bodySmall"
                        color: Theme.subtextDim
                        wrapMode: Text.WordWrap
                        text: "В разделе лимитов расходная шкала становится жёлтой с этого порога и красной при 85% и выше."
                    }
                }
            }
        }
    }

    // ── аккуратный хвост настроек: перечитать конфиг ──────────────────────
    RowLayout {
        visible: page.tab === "settings"
        Layout.alignment: Qt.AlignHCenter
        spacing: Theme.dp(8)

        Button {
            text: "Перечитать конфиг"
            icon: "refresh"
            variant: "tonal"
            disabled: GoUsage.ctlBusy
            onClicked: GoUsage.runCtl(["reload"], page._ctlDone)
        }
    }

    // статус последнего действия ctl (виден на обеих вкладках)
    LText {
        visible: page.ctlStatus !== ""
        Layout.fillWidth: true
        role: "bodySmall"
        color: page.ctlFailed ? Theme.fgErrorContainer : Theme.subtext
        wrapMode: Text.WrapAnywhere
        text: page.ctlStatus
    }
}
