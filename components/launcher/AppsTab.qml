import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"

// Вкладка «Приложения» на анатомии Lucid LauncherList: строка 56, ведущий слот
// 40 (иконка приложения без плитки, символьный фолбэк — на плитке), имя
// bodyLarge + комментарий bodySmall, справа точка работающего окна; выбранная
// строка — secondaryContainer с радиусом rad(14), ховер — StateLayer.
// Калькулятор отвечает на собственной карточке (DockCalc): labelMedium-подпись
// и крупный result над результатами. Pin/hide — на ховере. Фильтр по
// name/comment/keywords, закреплённые вперёд, запуск по клику или Enter.
Item {
    id: root

    property string query: ""
    property int sel: 0
    property var shell: null
    property var bootSystems: []
    property var pendingBoot: null
    readonly property string bootosScript: Quickshell.env("HOME") + "/oberon/scripts/bootos.sh"

    signal hovered(int index)
    signal selectionRequested(int index)

    // ── m3-метрики строки (через масштаб Oberon) ──────────────────────
    readonly property int rowH: Theme.dp(56)
    readonly property int calcH: Theme.dp(88)
    readonly property int leadSlot: Theme.dp(40)
    readonly property int edge: Theme.dp(16)
    readonly property int between: Theme.dp(12)
    readonly property int selRadius: Theme.radiusMd

    readonly property var apps: {
        const q = root.query.toLowerCase().trim();
        const out = [];
        for (const a of DesktopEntries.applications.values) {
            if (a.noDisplay) continue;
            if (Apps.isHidden(a) && !Apps.showHidden) continue;
            const name = (a.name || "").toLowerCase();
            const comment = (a.comment || "").toLowerCase();
            const kwSrc = Array.isArray(a.keywords) ? a.keywords.join(" ") : (a.keywords || "");
            const kw = String(kwSrc).toLowerCase();
            if (q === "" || name.includes(q) || comment.includes(q) || kw.includes(q)) out.push(a);
        }
        out.sort((x, y) => {
            const px = Apps.isPinned(x), py = Apps.isPinned(y);
            if (px !== py) return px ? -1 : 1;
            return (x.name || "").localeCompare(y.name || "");
        });
        return out.slice(0, 60);
    }

    // ── индикатор работающего окна (Umbriel.windows → app_id) ─────────
    readonly property var runningSet: {
        const s = {};
        for (const w of Umbriel.windows) {
            if (!w || !w.app_id) continue;
            s[String(w.app_id).toLowerCase()] = true;
        }
        return s;
    }
    // первый токен команды записи (basename, как в PackagesTab/Switcher)
    function _base(a) {
        let first = "";
        if (Array.isArray(a.command) && a.command.length > 0) first = String(a.command[0]);
        else first = String(a.execString || a.command || "").trim().split(/\s+/)[0] || "";
        return first.split("/").pop();
    }
    function appRunning(a) {
        if (!a) return false;
        const s = root.runningSet;
        let id = a.id ? String(a.id) : "";
        if (id.endsWith(".desktop")) id = id.slice(0, -8);
        if (id !== "" && s[id.toLowerCase()] === true) return true;
        if (a.startupClass && s[String(a.startupClass).toLowerCase()] === true) return true;
        const base = root._base(a);
        return base !== "" && s[base.toLowerCase()] === true;
    }

    // ── калькулятор: строка «= результат» над приложениями ────────────
    // экранирование одинарных кавычек для sh
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // «математическая» строка: только цифры, операторы и скобки,
    // обязательно есть цифра и хотя бы один оператор
    readonly property string calcResult: {
        const q = root.query.trim();
        if (q === "" || !/^[0-9+\-*/().,%^ ]+$/.test(q)) return "";
        if (!/[0-9]/.test(q)) return "";
        if (!/[+\-*/%^]/.test(q)) return "";
        return root.calcEval(q);
    }
    readonly property var calcRow: ({
        calc: true,
        name: root.calcResult,
        comment: "Результат · Enter — скопировать",
        icon: "calculate"
    })
    readonly property var bootRows: {
        const q = root.query.trim().toLowerCase();
        if (q === "" || root.bootSystems.length === 0) return [];
        const named = root.bootSystems.filter(function (system) {
            const name = String(system.name || "").toLowerCase();
            return name !== "" && (name.indexOf(q) !== -1 || q.indexOf(name) !== -1);
        });
        const keyword = ["ос", "boot", "загруз", "windows", "linux"].some(function (word) {
            return q.indexOf(word) !== -1;
        });
        const matches = named.length > 0 ? named : (keyword ? root.bootSystems : []);
        return matches.map(function (system) {
            return {
                boot: true,
                id: String(system.id),
                osName: String(system.name),
                name: "Загрузиться в " + String(system.name),
                comment: "Система перезагрузится",
                kind: String(system.kind || "other")
            };
        });
    }
    // модель списка: калькулятор, затем подходящие системы и приложения
    readonly property var rows: {
        const items = root.bootRows.concat(root.apps);
        return root.calcResult !== "" ? [root.calcRow].concat(items) : items;
    }
    readonly property int count: root.rows.length

    implicitHeight: Theme.dp(440)

    Process {
        id: bootListProc
        command: ["bash", root.bootosScript, "list"]
        running: true
        stdout: SplitParser {
            onRead: line => {
                try {
                    const result = JSON.parse(line);
                    root.bootSystems = Array.isArray(result)
                        ? result.filter(function (system) {
                            return system && system.id !== undefined && system.name;
                        }) : [];
                } catch (e) {
                    root.bootSystems = [];
                }
            }
        }
    }

    function cancelBoot() {
        root.pendingBoot = null;
    }

    function confirmBoot() {
        const system = root.pendingBoot;
        if (!system) return;
        root.pendingBoot = null;
        if (root.shell) root.shell.closeOverlays();
        Quickshell.execDetached([
            "sh", "-c", "pkexec \"$1\" boot \"$2\" && systemctl reboot",
            "sh", root.bootosScript, String(system.id)
        ]);
    }

    function activate(index) {
        // индекс 0 занят строкой калькулятора — копируем результат
        if (root.calcResult !== "" && index === 0) {
            Quickshell.execDetached(["sh", "-c", "printf %s " + root.shq(root.calcResult) + " | wl-copy"]);
            if (root.shell) root.shell.closeOverlays();
            return;
        }
        const a = root.rows[index];
        if (!a) return;
        if (root.pendingBoot) {
            if (a.boot === true && String(root.pendingBoot.id) === String(a.id))
                root.confirmBoot();
            return;
        }
        if (a.boot === true) {
            root.pendingBoot = a;
            return;
        }
        let cmd = a.command;
        if (typeof cmd === "string") cmd = ["sh", "-c", cmd];
        Quickshell.execDetached(cmd);
        if (root.shell) root.shell.closeOverlays();
    }

    function moveSel(delta) {
        if (root.count > 0) root.selectionRequested(root.sel + delta);
    }

    // ── упрощённый вычислитель (порт luciddocks/DockCalc.qml) ─────────
    // только числа и операторы + - * / % ^, унарный минус, скобки,
    // степень право-ассоциативна; на любой мусор/NaN/∞ — пусто
    function calcTokenize(src) {
        var out = [];
        var i = 0;
        while (i < src.length) {
            var ch = src.charAt(i);
            if (ch === " " || ch === "\t" || ch === ",") { i++; continue; }
            if ((ch >= "0" && ch <= "9") || ch === ".") {
                var s = i;
                while (i < src.length && ((src.charAt(i) >= "0" && src.charAt(i) <= "9") || src.charAt(i) === ".")) i++;
                var n = parseFloat(src.substring(s, i));
                if (isNaN(n)) return null;
                out.push({ t: "num", v: n });
                continue;
            }
            if ("+-*/%^()".indexOf(ch) !== -1) { out.push({ t: ch, v: ch }); i++; continue; }
            return null;
        }
        return out;
    }
    function calcParseExpr(tk, p) {
        var left = root.calcParseTerm(tk, p);
        if (!left) return null;
        while (left.next < tk.length && (tk[left.next].t === "+" || tk[left.next].t === "-")) {
            var op = tk[left.next].t;
            var right = root.calcParseTerm(tk, left.next + 1);
            if (!right) return null;
            left = { value: op === "+" ? left.value + right.value : left.value - right.value, next: right.next };
        }
        return left;
    }
    function calcParseTerm(tk, p) {
        var left = root.calcParsePower(tk, p);
        if (!left) return null;
        while (left.next < tk.length && (tk[left.next].t === "*" || tk[left.next].t === "/" || tk[left.next].t === "%")) {
            var op = tk[left.next].t;
            var right = root.calcParsePower(tk, left.next + 1);
            if (!right) return null;
            var v = op === "*" ? left.value * right.value : (op === "/" ? left.value / right.value : left.value % right.value);
            left = { value: v, next: right.next };
        }
        return left;
    }
    function calcParsePower(tk, p) {
        var base = root.calcParseUnary(tk, p);
        if (!base) return null;
        if (base.next < tk.length && tk[base.next].t === "^") {
            var exp = root.calcParsePower(tk, base.next + 1);
            if (!exp) return null;
            return { value: Math.pow(base.value, exp.value), next: exp.next };
        }
        return base;
    }
    function calcParseUnary(tk, p) {
        if (p < tk.length && (tk[p].t === "-" || tk[p].t === "+")) {
            var sign = tk[p].t === "-" ? -1 : 1;
            var inner = root.calcParseUnary(tk, p + 1);
            if (!inner) return null;
            return { value: sign * inner.value, next: inner.next };
        }
        return root.calcParsePrimary(tk, p);
    }
    function calcParsePrimary(tk, p) {
        if (p >= tk.length) return null;
        var t = tk[p];
        if (t.t === "num") return { value: t.v, next: p + 1 };
        if (t.t === "(") {
            var inner = root.calcParseExpr(tk, p + 1);
            if (!inner || inner.next >= tk.length || tk[inner.next].t !== ")") return null;
            return { value: inner.value, next: inner.next + 1 };
        }
        return null;
    }
    function calcEval(src) {
        var tk = root.calcTokenize(src);
        if (!tk || tk.length === 0) return "";
        var res = root.calcParseExpr(tk, 0);
        if (!res || res.next !== tk.length) return "";
        if (typeof res.value !== "number" || !isFinite(res.value)) return "";
        return root.calcFormat(res.value);
    }
    function calcFormat(v) {
        if (Math.abs(v) >= 1e15 || (v !== 0 && Math.abs(v) < 1e-6))
            return v.toExponential(6).replace(/e([+-])(\d)$/, "e$10$2");
        var r = Math.round(v * 1e10) / 1e10;
        var s = r.toString();
        if (s.indexOf(".") !== -1) s = s.replace(/0+$/, "").replace(/\.$/, "");
        return s;
    }

    onSelChanged: if (root.sel >= 0 && root.sel < appList.count) appList.positionViewAtIndex(root.sel, ListView.Contain)

    ListView {
        id: appList

        anchors.fill: parent
        model: root.rows
        clip: true
        spacing: Theme.dp(4)

        delegate: Item {
            id: rowItem

            required property var modelData
            required property int index

            readonly property bool isCalc: modelData !== null && modelData.calc === true
            readonly property bool isBoot: modelData !== null && modelData.boot === true
            readonly property bool selected: rowItem.index === root.sel && !rowItem.isCalc
            readonly property bool app: !rowItem.isCalc && !rowItem.isBoot
            readonly property string iconPath: (rowItem.app && modelData.icon) ? Quickshell.iconPath(modelData.icon, true) : ""
            readonly property bool hasIcon: rowItem.iconPath !== ""
            readonly property bool running: rowItem.app && root.appRunning(modelData)
            readonly property bool pinned: rowItem.app && Apps.isPinned(modelData)
            readonly property bool hidden: rowItem.app && Apps.isHidden(modelData)
            readonly property bool showActions: rowItem.app && (rowItem.hovering || rowItem.pinned || rowItem.hidden)
            property bool hovering: false

            width: appList.width
            height: rowItem.isCalc ? root.calcH : root.rowH

            HoverHandler {
                onHoveredChanged: {
                    rowItem.hovering = hovered;
                    if (hovered) root.hovered(rowItem.index);
                }
            }

            ListItem {
                id: appSurface

                anchors.fill: parent
                visible: !rowItem.isCalc
                headline: rowItem.modelData.name || ""
                headlineRole: "bodyLarge"
                headlineWeight: Theme.typeWeight("bodyLarge")
                headlineTrailingVisible: rowItem.running
                supporting: rowItem.modelData.comment || ""
                supportingRole: "bodySmall"
                textSpacing: 0
                selected: rowItem.selected
                clickable: true
                containerColor: "transparent"
                stateTint: rowItem.selected ? Theme.fgSecondaryContainer : Theme.text
                outerRadius: root.selRadius
                innerRadius: root.selRadius
                leadingMargin: root.edge
                leadingTextSpacing: root.between
                textTrailingSpacing: rowItem.showActions ? root.between : 0
                trailingMargin: root.edge
                trailingSpacing: root.between
                onClicked: root.activate(rowItem.index)

                leading: Item {
                    anchors.fill: parent

                    Rectangle {
                        anchors.fill: parent
                        visible: !rowItem.hasIcon
                        radius: parent.width / 2
                        color: Theme.bgTile
                    }

                    AppIcon {
                        anchors.centerIn: parent
                        visible: rowItem.hasIcon
                        source: rowItem.iconPath
                        size: Theme.dp(36)
                        radius: size / 2
                    }

                    Icon {
                        anchors.centerIn: parent
                        visible: !rowItem.hasIcon
                        name: rowItem.isBoot ? "restart_alt" : "apps"
                        size: Theme.dp(22)
                        color: rowItem.selected ? Theme.fgSecondaryContainer : Theme.subtext
                    }
                }

                headlineTrailing: Rectangle {
                    width: Theme.dp(6)
                    height: Theme.dp(6)
                    anchors.verticalCenter: parent.verticalCenter
                    radius: width / 2
                    color: rowItem.selected ? Theme.fgSecondaryContainer : Theme.primary
                }

                trailing: Row {
                    visible: rowItem.showActions
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: root.between

                    IconButton {
                        icon: "push_pin"
                        size: "s"
                        variant: rowItem.pinned ? "filled" : "tonal"
                        onClicked: Apps.togglePin(rowItem.modelData)
                    }

                    IconButton {
                        icon: rowItem.hidden ? "visibility_off" : "visibility"
                        size: "s"
                        variant: rowItem.hidden ? "filled" : "tonal"
                        onClicked: Apps.toggleHide(rowItem.modelData)
                    }
                }
            }

            // Калькулятор остаётся отдельной карточкой; приложения используют
            // state layer самой ListItem.
            StateLayer {
                visible: rowItem.isCalc
                radius: Theme.shapeXl
                tint: rowItem.index === root.sel ? Theme.fgSecondaryContainer : Theme.text
                onClicked: root.activate(rowItem.index)
            }

            // ── карточка калькулятора (DockCalc) ──────────────────────
            Rectangle {
                anchors.fill: parent
                visible: rowItem.isCalc
                radius: Theme.shapeXl
                color: rowItem.index === root.sel ? Theme.secondaryContainer : Theme.mHigh

                Behavior on color {
                    ColorAnimation { duration: Theme.durDefaultEffects }
                }

                Column {
                    x: root.edge + Theme.dp(4)
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - x - Theme.dp(72)
                    spacing: Theme.dp(2)

                    LText {
                        width: parent.width
                        elide: Text.ElideRight
                        role: "labelMedium"
                        text: rowItem.modelData.comment || ""
                        color: rowItem.index === root.sel
                               ? Theme.alpha(Theme.fgSecondaryContainer, 0.75) : Theme.subtextDim
                    }
                    LText {
                        width: parent.width
                        elide: Text.ElideRight
                        tabular: true
                        role: "headlineMedium"
                        text: root.calcResult
                        color: rowItem.index === root.sel ? Theme.fgSecondaryContainer : Theme.primary
                    }
                }

                Column {
                    anchors.right: parent.right
                    anchors.rightMargin: root.edge + Theme.dp(4)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.dp(4)

                    Icon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: "content_paste"
                        size: Theme.dp(20)
                        color: rowItem.index === root.sel
                               ? Theme.alpha(Theme.fgSecondaryContainer, 0.85) : Theme.subtextDim
                    }
                    LText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        role: "labelSmall"
                        text: "Return"
                        color: rowItem.index === root.sel
                               ? Theme.alpha(Theme.fgSecondaryContainer, 0.75) : Theme.subtextDim
                    }
                }
            }

        }
    }

    Item {
        anchors.fill: parent
        visible: root.pendingBoot !== null
        z: 10

        Rectangle {
            anchors.fill: parent
            color: Theme.a(Theme.scrim, 0.48)

            MouseArea {
                anchors.fill: parent
                onClicked: root.cancelBoot()
            }
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.dp(32), Theme.dp(380))
            height: bootConfirmLayout.implicitHeight + Theme.dp(40)
            radius: Theme.shapeXl
            color: Theme.mHigh

            ColumnLayout {
                id: bootConfirmLayout
                anchors.fill: parent
                anchors.margins: Theme.dp(20)
                spacing: Theme.dp(10)

                LText {
                    Layout.fillWidth: true
                    role: "titleLarge"
                    text: root.pendingBoot ? "Загрузиться в " + root.pendingBoot.osName + "?" : ""
                    wrapMode: Text.WordWrap
                    color: Theme.text
                }

                LText {
                    Layout.fillWidth: true
                    role: "bodyMedium"
                    text: "Система перезагрузится"
                    color: Theme.subtext
                    wrapMode: Text.WordWrap
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(4)
                    Item { Layout.fillWidth: true }
                    Button {
                        size: "s"
                        variant: "text"
                        text: "Отмена"
                        onClicked: root.cancelBoot()
                    }
                    Button {
                        size: "s"
                        variant: "filled"
                        text: "Загрузиться"
                        onClicked: root.confirmBoot()
                    }
                }
            }
        }
    }

    LText { // пусто / нет результатов поиска
        anchors.centerIn: parent
        visible: appList.count === 0
        text: root.query.trim() !== "" ? "Ничего не найдено" : "Пусто"
        role: "bodyMedium"
        color: Theme.subtext
    }
}
