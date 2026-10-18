import QtQuick

// Вогнутый угол примыкания капсулы к кромке экрана.
Canvas {
    id: corner

    property string side: "left"
    property color fill: "#000000"
    property real r: 12

    width: r
    height: r

    onFillChanged: requestPaint()
    onRChanged: requestPaint()
    onSideChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        ctx.fillStyle = corner.fill;
        ctx.beginPath();

        if (side === "left") {
            ctx.moveTo(0, 0);
            ctx.lineTo(r, 0);
            ctx.lineTo(r, r);
            ctx.arc(0, r, r, 0, -Math.PI / 2, true);
        } else {
            ctx.moveTo(r, 0);
            ctx.lineTo(0, 0);
            ctx.lineTo(0, r);
            ctx.arc(r, r, r, Math.PI, -Math.PI / 2, false);
        }

        ctx.closePath();
        ctx.fill();
    }
}
