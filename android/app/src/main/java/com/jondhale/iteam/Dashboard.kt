package com.jondhale.iteam

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

// Shared dashboard pieces in the violet card style (stat tiles, charts, task cards).

val Violet get() = LookState.primary
private val violetBrush get() = Brush.linearGradient(listOf(LookState.primary, LookState.primary.copy(alpha = 0.85f), LookState.secondary))

/** "Hello, Name" + big headline + optional action, like the reference designs. */
@Composable
fun DashHeader(hello: String, headline: String, action: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 12.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(hello, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(headline, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        }
        action?.invoke()
    }
}

@Composable
fun StatTile(label: String, value: String, modifier: Modifier = Modifier, highlight: Boolean = false, onClick: (() -> Unit)? = null) {
    Column(modifier.shadow(if (highlight) 10.dp else 2.dp, RoundedCornerShape(22.dp), spotColor = Violet)
        .clip(RoundedCornerShape(22.dp))
        .background(if (highlight) violetBrush else Brush.linearGradient(listOf(MaterialTheme.colorScheme.surfaceContainer, MaterialTheme.colorScheme.surfaceContainer)))
        .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
        .padding(14.dp)) {
        Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = if (highlight) Color.White else MaterialTheme.colorScheme.onSurface)
        Text(label, style = MaterialTheme.typography.labelMedium, color = if (highlight) Color.White.copy(alpha = 0.85f) else MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

@Composable
fun StatRow(vararg tiles: Triple<String, String, (() -> Unit)?>) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        tiles.forEachIndexed { i, t -> StatTile(t.first, t.second, Modifier.weight(1f), highlight = i == 0, onClick = t.third) }
    }
}

@Composable
fun SectionTitle(title: String, count: Int? = null, action: String? = null, onAction: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 16.dp, top = 16.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        if (count != null) Text("$count", Modifier.clip(CircleShape).background(Violet).padding(horizontal = 9.dp, vertical = 3.dp),
            color = Color.White, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
        if (action != null && onAction != null) TextButton(onAction) { Text(action) }
    }
}

/** Overlapping round initials, "+3" after four. */
@Composable
fun AvatarStack(names: List<String>, onDark: Boolean = true) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        names.take(4).forEachIndexed { i, n ->
            Box(Modifier.offset(x = (-8 * i).dp).size(30.dp).border(2.dp, if (onDark) Color.White else MaterialTheme.colorScheme.surface, CircleShape)
                .clip(CircleShape).background(Color(0xFFB794F6 - i * 0x101010)), contentAlignment = Alignment.Center) {
                Text(n.take(1).uppercase(), color = Color.White, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
            }
        }
        if (names.size > 4) Text("+${names.size - 4}", Modifier.offset(x = (-24).dp), color = if (onDark) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.labelMedium)
    }
}

/** The big violet card (group task / item) with progress, date line, people and a + button. */
@Composable
fun VioletCard(title: String, subtitle: String, dateLine: String, footer: String, people: List<String>, progress: Float?,
               modifier: Modifier = Modifier, filled: Boolean = true, onClick: () -> Unit) {
    val fg = if (filled) Color.White else MaterialTheme.colorScheme.onSurface
    Column(modifier.shadow(if (filled) 14.dp else 3.dp, RoundedCornerShape(26.dp), spotColor = Violet).clip(RoundedCornerShape(26.dp))
        .background(if (filled) violetBrush else Brush.linearGradient(listOf(MaterialTheme.colorScheme.surfaceVariant, MaterialTheme.colorScheme.surfaceVariant)))
        .clickable(onClick = onClick).padding(16.dp)) {
        Text(subtitle, color = fg.copy(alpha = 0.8f), style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (progress != null) {
            Spacer(Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                LinearProgressIndicator({ progress }, Modifier.weight(1f).height(5.dp).clip(RoundedCornerShape(3.dp)),
                    color = Color(0xFFFF5A7A), trackColor = fg.copy(alpha = 0.2f))
                Text("  ${(progress * 100).toInt()}%", color = fg, style = MaterialTheme.typography.labelSmall)
            }
        }
        Spacer(Modifier.height(10.dp))
        if (dateLine.isNotEmpty()) Text(dateLine, color = fg.copy(alpha = 0.75f), style = MaterialTheme.typography.labelSmall)
        Text(title, color = fg, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(18.dp).clip(CircleShape).background(Color(0xFFFF5A7A)), contentAlignment = Alignment.Center) { Text("⏱", style = MaterialTheme.typography.labelSmall) }
            Text("  $footer", color = fg.copy(alpha = 0.9f), style = MaterialTheme.typography.labelMedium, modifier = Modifier.weight(1f))
        }
        if (people.isNotEmpty()) { Spacer(Modifier.height(10.dp)); AvatarStack(people, onDark = filled) }
    }
}

@Composable
fun HorizontalCards(content: @Composable RowScope.() -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), content = content)
}

/** Bar chart card: one bar per label (e.g. last 7 days). */
@Composable
fun BarChartCard(title: String, total: String, labels: List<String>, values: List<Float>) {
    ChartCard(title, total) {
        val max = (values.maxOrNull() ?: 0f).coerceAtLeast(1f)
        val c = Violet
        Canvas(Modifier.fillMaxWidth().height(120.dp)) {
            val n = values.size.coerceAtLeast(1)
            val slot = size.width / n
            val w = slot * 0.5f
            values.forEachIndexed { i, v ->
                val h = size.height * (v / max)
                drawRoundRect(c.copy(alpha = if (i == n - 1) 1f else 0.35f), Offset(i * slot + (slot - w) / 2, size.height - h), Size(w, h.coerceAtLeast(4f)), CornerRadius(10f, 10f))
            }
        }
        Row(Modifier.fillMaxWidth()) { labels.forEach { Text(it, Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center) } }
    }
}

/** Smooth line chart card (trend). */
@Composable
fun LineChartCard(title: String, total: String, labels: List<String>, values: List<Float>) {
    ChartCard(title, total) {
        val max = (values.maxOrNull() ?: 0f).coerceAtLeast(1f)
        val c = Violet
        Canvas(Modifier.fillMaxWidth().height(110.dp)) {
            if (values.size < 2) return@Canvas
            val step = size.width / (values.size - 1)
            val pts = values.mapIndexed { i, v -> Offset(i * step, size.height - size.height * (v / max) * 0.9f - 4f) }
            val p = Path().apply {
                moveTo(pts[0].x, pts[0].y)
                for (i in 1 until pts.size) {
                    val a = pts[i - 1]; val b = pts[i]; val mx = (a.x + b.x) / 2
                    cubicTo(mx, a.y, mx, b.y, b.x, b.y)
                }
            }
            val fill = Path().apply { addPath(p); lineTo(size.width, size.height); lineTo(0f, size.height); close() }
            drawPath(fill, Brush.verticalGradient(listOf(c.copy(alpha = 0.25f), Color.Transparent)))
            drawPath(p, c, style = Stroke(width = 6f))
            drawCircle(c, 9f, pts.last()); drawCircle(Color.White, 4f, pts.last())
        }
        Row(Modifier.fillMaxWidth()) { labels.forEach { Text(it, Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center) } }
    }
}

@Composable
private fun ChartCard(title: String, total: String, body: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp).shadow(3.dp, RoundedCornerShape(24.dp)).clip(RoundedCornerShape(24.dp))
        .background(MaterialTheme.colorScheme.surfaceContainer).padding(16.dp)) {
        Text(title, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
        Text(total, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        body()
    }
}

/** Day labels (Mon…) and day starts for the last n days, oldest first. */
fun lastDays(n: Int): List<Pair<String, Long>> {
    val cal = java.util.Calendar.getInstance().apply { set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0); set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0) }
    val fmt = java.text.SimpleDateFormat("EEE", java.util.Locale.getDefault())
    return (n - 1 downTo 0).map { back ->
        val c = cal.clone() as java.util.Calendar; c.add(java.util.Calendar.DAY_OF_YEAR, -back)
        fmt.format(c.time).take(3) to c.timeInMillis
    }
}
