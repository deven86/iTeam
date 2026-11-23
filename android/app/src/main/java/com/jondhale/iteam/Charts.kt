package com.jondhale.iteam

import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/** Charts like the iPhone app: pie = shares of a whole, bar = amounts per item or month, line = trend over time. */
data class Chart(val kind: Kind, val title: String, val labels: List<String>, val values: List<Double>) {
    enum class Kind { PIE, BAR, LINE }
    val usable get() = values.isNotEmpty() && values.any { it > 0 } && (kind != Kind.LINE || values.size >= 2)
}

object Charts {
    val palette = listOf(0xFF5B5BF7, 0xFF00B4D8, 0xFF34C759, 0xFFFF9500, 0xFFFF3B30, 0xFFAF52DE, 0xFFFFCC00, 0xFF8E8E93)

    /** Last [n] months, oldest first: labels like "Jun" and each month's start/end in millis. */
    fun months(n: Int = 6): List<Triple<String, Long, Long>> {
        val fmt = SimpleDateFormat("MMM", Locale.ENGLISH)
        return (n - 1 downTo 0).map { back ->
            val c = Calendar.getInstance().apply { set(Calendar.DAY_OF_MONTH, 1); set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0); add(Calendar.MONTH, -back) }
            val start = c.timeInMillis; c.add(Calendar.MONTH, 1)
            Triple(fmt.format(java.util.Date(start)), start, c.timeInMillis)
        }
    }

    fun <T> perMonth(title: String, items: List<T>, kind: Chart.Kind = Chart.Kind.BAR, n: Int = 6, time: (T) -> Long?, value: (T) -> Double = { 1.0 }): Chart {
        val ms = months(n)
        return Chart(kind, title, ms.map { it.first }, ms.map { (_, a, b) -> items.filter { t -> time(t)?.let { it in a until b } == true }.sumOf(value) })
    }

    /** Top groups (others merged) for a pie or bar. */
    fun <T> grouped(title: String, items: List<T>, kind: Chart.Kind = Chart.Kind.PIE, top: Int = 6, key: (T) -> String, value: (T) -> Double = { 1.0 }): Chart {
        val g = items.groupBy(key).mapValues { e -> e.value.sumOf(value) }.filter { it.value > 0 }.toList().sortedByDescending { it.second }
        val head = g.take(top); val rest = g.drop(top).sumOf { it.second }
        val all = if (rest > 0) head + ("Other" to rest) else head
        return Chart(kind, title, all.map { it.first.ifEmpty { "—" } }, all.map { it.second })
    }

    private fun short(v: Double): String = when {
        v >= 1e7 -> "%.1fCr".format(v / 1e7); v >= 1e5 -> "%.1fL".format(v / 1e5); v >= 1e3 -> "%.1fk".format(v / 1e3)
        v == Math.floor(v) -> v.toLong().toString(); else -> "%.1f".format(v)
    }

    // MARK: PDF (android.graphics)

    fun draw(c: android.graphics.Canvas, ch: Chart, r: RectF) {
        val title = Paint().apply { isAntiAlias = true; textSize = 11f; typeface = Typeface.DEFAULT_BOLD }
        val small = Paint().apply { isAntiAlias = true; textSize = 8f; color = 0xFF555555.toInt() }
        c.drawRoundRect(r, 10f, 10f, Paint().apply { color = 0xFFF5F5FA.toInt() })
        c.drawText(ch.title, r.left + 10, r.top + 16, title)
        val area = RectF(r.left + 10, r.top + 26, r.right - 10, r.bottom - 10)
        val total = ch.values.sum().takeIf { it > 0 } ?: 1.0
        when (ch.kind) {
            Chart.Kind.PIE -> {
                val d = minOf(area.height(), area.width() * 0.45f)
                val o = RectF(area.left, area.top, area.left + d, area.top + d)
                var start = -90f
                ch.values.forEachIndexed { i, v ->
                    val sweep = (v / total * 360).toFloat()
                    c.drawArc(o, start, sweep, true, Paint().apply { isAntiAlias = true; color = palette[i % palette.size].toInt() })
                    start += sweep
                }
                var y = area.top + 8
                ch.labels.forEachIndexed { i, l ->
                    if (y > area.bottom) return@forEachIndexed
                    c.drawCircle(o.right + 12, y - 3, 3.5f, Paint().apply { isAntiAlias = true; color = palette[i % palette.size].toInt() })
                    c.drawText("${l.take(18)}  ${short(ch.values[i])} (${(ch.values[i] / total * 100).toInt()}%)", o.right + 20, y, small)
                    y += 12
                }
            }
            Chart.Kind.BAR -> {
                val max = ch.values.maxOrNull()?.takeIf { it > 0 } ?: 1.0
                val n = ch.values.size; val gap = 6f; val bw = (area.width() - gap * (n - 1)) / n
                ch.values.forEachIndexed { i, v ->
                    val h = ((area.height() - 22) * (v / max)).toFloat()
                    val x = area.left + i * (bw + gap)
                    c.drawRoundRect(RectF(x, area.bottom - 12 - h, x + bw, area.bottom - 12), 3f, 3f, Paint().apply { isAntiAlias = true; color = palette[0].toInt() })
                    if (v > 0) c.drawText(short(v), x, area.bottom - 15 - h, small)
                    c.drawText(ch.labels[i].take(8), x, area.bottom, small)
                }
            }
            Chart.Kind.LINE -> {
                val max = ch.values.maxOrNull() ?: 1.0; val min = ch.values.minOrNull() ?: 0.0
                val span = (max - min).takeIf { it > 0 } ?: 1.0
                val n = ch.values.size
                val pts = ch.values.mapIndexed { i, v -> (area.left + i * area.width() / (n - 1)) to (area.bottom - 14 - ((v - min) / span * (area.height() - 26)).toFloat()) }
                val line = Paint().apply { isAntiAlias = true; color = palette[1].toInt(); strokeWidth = 2f; style = Paint.Style.STROKE }
                for (i in 1 until pts.size) c.drawLine(pts[i - 1].first, pts[i - 1].second, pts[i].first, pts[i].second, line)
                pts.forEachIndexed { i, p ->
                    c.drawCircle(p.first, p.second, 2.5f, Paint().apply { isAntiAlias = true; color = palette[1].toInt() })
                    if (i == 0 || i == pts.size - 1 || n <= 8) c.drawText(short(ch.values[i]), p.first - 6, p.second - 5, small)
                    if (n <= 8 || i % (n / 6 + 1) == 0) c.drawText(ch.labels[i].take(6), p.first - 8, area.bottom, small)
                }
            }
        }
    }
}

// MARK: - In the app (Compose)

@Composable
fun ChartCard(ch: Chart, modifier: Modifier = Modifier) {
    if (!ch.usable) return
    Card(modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
        Column(Modifier.padding(12.dp)) {
            Text(ch.title, style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(8.dp))
            val total = ch.values.sum().takeIf { it > 0 } ?: 1.0
            when (ch.kind) {
                Chart.Kind.PIE -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Canvas(Modifier.size(110.dp)) {
                        var start = -90f
                        ch.values.forEachIndexed { i, v ->
                            val sweep = (v / total * 360).toFloat()
                            drawArc(Color(Charts.palette[i % Charts.palette.size]), start, sweep, useCenter = false, style = Stroke(width = size.minDimension * 0.22f),
                                topLeft = Offset(size.minDimension * 0.11f, size.minDimension * 0.11f), size = Size(size.minDimension * 0.78f, size.minDimension * 0.78f))
                            start += sweep
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    Column {
                        ch.labels.forEachIndexed { i, l ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(Modifier.size(9.dp).background(Color(Charts.palette[i % Charts.palette.size]), CircleShape))
                                Spacer(Modifier.width(6.dp))
                                Text("$l · ${(ch.values[i] / total * 100).toInt()}%", style = MaterialTheme.typography.labelSmall, maxLines = 1)
                            }
                        }
                    }
                }
                Chart.Kind.BAR -> {
                    val max = ch.values.maxOrNull()?.takeIf { it > 0 } ?: 1.0
                    Row(Modifier.fillMaxWidth().height(120.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Bottom) {
                        ch.values.forEachIndexed { i, v ->
                            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Bottom) {
                                Box(Modifier.fillMaxWidth().fillMaxHeight((v / max).toFloat().coerceIn(0.02f, 0.82f))
                                    .background(Color(Charts.palette[0]), RoundedCornerShape(topStart = 4.dp, topEnd = 4.dp)))
                                Text(ch.labels[i].take(6), style = MaterialTheme.typography.labelSmall, maxLines = 1)
                            }
                        }
                    }
                }
                Chart.Kind.LINE -> {
                    val col = Color(Charts.palette[1])
                    Canvas(Modifier.fillMaxWidth().height(110.dp)) {
                        val max = ch.values.maxOrNull() ?: 1.0; val min = ch.values.minOrNull() ?: 0.0
                        val span = (max - min).takeIf { it > 0 } ?: 1.0
                        val n = ch.values.size
                        val path = Path()
                        ch.values.forEachIndexed { i, v ->
                            val x = i * size.width / (n - 1); val y = size.height - ((v - min) / span * size.height * 0.85f).toFloat() - size.height * 0.05f
                            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                            drawCircle(col, 4f, Offset(x, y))
                        }
                        drawPath(path, col, style = Stroke(width = 4f))
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(ch.labels.first(), style = MaterialTheme.typography.labelSmall); Text(ch.labels.last(), style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
    }
}

// MARK: - Chart sets per module (shared by the screens and the PDFs)

object ModuleCharts {
    fun finance(app: AppState, book: String): List<Chart> {
        val all = app.store.finList().filter { it.s("book") == book && !it.deleted && it.status == "paid" }
        val outs = all.filter { !it.isIn }
        return listOf(
            Charts.perMonth("Income per month", all.filter { it.isIn }, time = { it.finDate }, value = { it.amount }),
            Charts.perMonth("Expenses per month", outs, time = { it.finDate }, value = { it.amount }),
            Charts.grouped("Expenses by category", outs.filter { it.finDate >= Charts.months(1).first().second }, key = { it.s("category") }, value = { it.amount }),
        ).filter { it.usable }
    }

    fun biz(app: AppState, spec: BizSpec): List<Chart> {
        val all = app.store.bizList(spec.module).filter { !it.deleted }
        val parents = spec.parent?.let { p -> all.filter { it.kind == p.id } } ?: emptyList()
        val out = mutableListOf<Chart>()
        if (parents.isNotEmpty()) out += Chart(Chart.Kind.BAR, "${spec.balanceLabel} by ${spec.parent?.label?.lowercase()}",
            parents.take(8).map { it.title.take(10) }, parents.take(8).map { p -> Biz.balance(spec, all.filter { it.parentID == p.id }).coerceAtLeast(0.0) })
        out += Charts.grouped("Status of entries", all.filter { it.status.isNotEmpty() && it.kind != spec.parent?.id }, key = { it.status })
        out += Charts.perMonth("Money per month", all.filter { it.amount > 0 && it.kind != spec.parent?.id }, time = { it.date ?: it.due }, value = { it.amount })
        return out.filter { it.usable }
    }

    fun crm(app: AppState): List<Chart> {
        val leads = app.store.miscList("crml").filter { !it.deleted }
        return listOf(Charts.grouped("Leads by stage", leads, key = { it.s("stage").replaceFirstChar { c -> c.uppercase() } }),
            Charts.grouped("Pipeline value by stage", leads.filter { it.s("stage") !in listOf("lost") }, Chart.Kind.BAR, key = { it.s("stage").replaceFirstChar { c -> c.uppercase() } }, value = { it.p.optDouble("dealValue", 0.0) }))
            .filter { it.usable }
    }

    fun build(app: AppState, projectID: String): List<Chart> {
        val all = app.store.buildList().filter { !it.deleted && it.projectID == projectID }
        return listOf(Charts.grouped("Units by status", all.filter { it.bkind == "unit" }, key = { it.status.ifEmpty { "Available" } }),
            Charts.grouped("Records by type", all, Chart.Kind.BAR, key = { BuildKinds.of(it.bkind).plural })).filter { it.usable }
    }

    fun gymMember(app: AppState, memberID: String): List<Chart> {
        val sessions = app.store.miscList("gymsess").filter { it.s("memberID") == memberID && !it.deleted }
        val pays = app.store.miscList("gympay").filter { it.s("memberID") == memberID && !it.deleted }
        val weights = app.store.miscList("gymphoto").filter { it.s("memberID") == memberID && !it.deleted && it.p.optDouble("weight", 0.0) > 0 }
            .sortedBy { it.p.optDouble("date") }
        val out = mutableListOf(
            Charts.perMonth("Sessions per month", sessions, time = { SwiftDate.toMillis(it.p.optDouble("date")) }),
            Charts.grouped("Workout mix", sessions, key = { it.s("workout").ifEmpty { "Other" } }),
            Charts.perMonth("Payments per month", pays, time = { SwiftDate.toMillis(it.p.optDouble("date")) }, value = { it.amount }),
        )
        if (weights.size >= 2) out += Chart(Chart.Kind.LINE, "Weight (kg)", weights.map { dateText(SwiftDate.toMillis(it.p.optDouble("date"))).take(6) }, weights.map { it.p.optDouble("weight") })
        return out.filter { it.usable }
    }

    fun gymAll(app: AppState): List<Chart> {
        val sessions = app.store.miscList("gymsess").filter { !it.deleted }
        val pays = app.store.miscList("gympay").filter { !it.deleted }
        return listOf(Charts.perMonth("Sessions per month (everyone)", sessions, time = { SwiftDate.toMillis(it.p.optDouble("date")) }),
            Charts.perMonth("Payments per month", pays, time = { SwiftDate.toMillis(it.p.optDouble("date")) }, value = { it.amount }),
            Charts.grouped("Workout mix", sessions, key = { it.s("workout").ifEmpty { "Other" } })).filter { it.usable }
    }

    fun society(app: AppState): List<Chart> {
        val soc = app.store.miscList("soc").filter { !it.deleted }
        return listOf(Charts.grouped("Complaints by status", soc.filter { it.s("kind") == "complaint" }, key = { it.status.ifEmpty { "open" } }),
            Charts.grouped("Bills", soc.filter { it.s("kind") == "bill" }, key = { it.status.ifEmpty { "due" } })).filter { it.usable }
    }
}

/** Gym & Training: a full PDF for one person, like iLife's export — profile, memberships, stats, charts, sessions and payments. */
object GymReport {
    fun lines(app: AppState, memberID: String): List<String> {
        val m = app.sync.misc("gymm", memberID) ?: return emptyList()
        val sessions = app.store.miscList("gymsess").filter { it.s("memberID") == memberID && !it.deleted }.sortedByDescending { it.p.optDouble("date") }
        val pays = app.store.miscList("gympay").filter { it.s("memberID") == memberID && !it.deleted }.sortedByDescending { it.p.optDouble("date") }
        val plans = app.store.miscList("gymplan").filter { it.s("memberID") == memberID && !it.deleted }
        val weights = app.store.miscList("gymphoto").filter { it.s("memberID") == memberID && !it.deleted && it.p.optDouble("weight", 0.0) > 0 }.sortedBy { it.p.optDouble("date") }
        fun d(r: Rec, k: String = "date") = dateText(SwiftDate.toMillis(r.p.optDouble(k)))
        val monthStart = Charts.months(1).first().second
        val out = mutableListOf("## Profile")
        out += "Name: ${m.s("name")}" + (if (m.s("relation").isNotEmpty()) " · ${m.s("relation")}" else "")
        if (m.s("goal").isNotEmpty()) out += "Goal: ${m.s("goal")}"
        if (m.s("trainer").isNotEmpty()) out += "Trainer: ${m.s("trainer")}"
        out += "Managed by ${app.store.name(m.owner)}"
        out += "## Summary"
        out += "Sessions: ${sessions.size} in total · ${sessions.count { SwiftDate.toMillis(it.p.optDouble("date")) >= monthStart }} this month"
        if (sessions.size >= 2) {
            val first = SwiftDate.toMillis(sessions.last().p.optDouble("date")); val weeks = ((System.currentTimeMillis() - first) / (7 * 86_400_000.0)).coerceAtLeast(1.0)
            out += "Average: ${"%.1f".format(sessions.size / weeks)} sessions a week since ${dateText(first)}"
        }
        out += "Paid: ${money(pays.sumOf { it.amount })}" + pays.groupBy { it.s("kind") }.map { (k, l) -> " · ${gymPayKinds.firstOrNull { it.first == k }?.second ?: k} ${money(l.sumOf { it.amount })}" }.joinToString("")
        val fee = m.p.optDouble("fee", 0.0)
        if (fee > 0) out += "Training balance: ${money(sessions.size * fee - pays.filter { it.s("kind") == "training" }.sumOf { it.amount })} (₹${fee.toLong()} per session)"
        if (weights.size >= 2) out += "Weight: ${weights.first().p.optDouble("weight")} kg → ${weights.last().p.optDouble("weight")} kg"
        if (plans.isNotEmpty()) {
            out += "## Memberships"
            plans.forEach { p -> out += "• ${p.s("gymName")} · ${p.s("planName")} · ${d(p, "start")} – ${d(p, "end")} · ${money(p.p.optDouble("fee"))}" }
        }
        out += "## Workout mix"
        sessions.groupBy { it.s("workout").ifEmpty { "Other" } }.toList().sortedByDescending { it.second.size }.forEach { (w, l) -> out += "• $w: ${l.size}" }
        out += "## Sessions (${sessions.size})"
        sessions.forEach { s -> out += "• ${d(s)} · ${s.s("workout").ifEmpty { "Training session" }}" + (if (s.s("trainer").isNotEmpty()) " · ${s.s("trainer")}" else "") + (if (s.s("notes").isNotEmpty()) " — ${s.s("notes")}" else "") }
        out += "## Payments (${pays.size})"
        pays.forEach { p -> out += "• ${d(p)} · ${gymPayKinds.firstOrNull { it.first == p.s("kind") }?.second ?: p.s("kind")} · ${money(p.amount)} · ${p.s("method")}" }
        if (weights.isNotEmpty()) { out += "## Weight log"; weights.forEach { w -> out += "• ${d(w)} · ${w.p.optDouble("weight")} kg" } }
        return out
    }

    fun all(app: AppState): List<String> {
        val members = app.store.miscList("gymm").filter { !it.deleted }
        return members.flatMap { m -> listOf("## ${m.s("name")}") + lines(app, m.id).filter { !it.startsWith("## ") }.take(8) }
    }
}
