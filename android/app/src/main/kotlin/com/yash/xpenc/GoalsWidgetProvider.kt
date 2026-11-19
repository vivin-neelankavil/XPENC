package com.yash.xpenc

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray

/**
 * The home-screen "Goals & Loans" widget: showcases active savings goals
 * and loan balances in dedicated, properly split GOALS and LOANS sections with
 * individual progress bars, count headers, and a top summary banner.
 *
 * Data (`goals_summary`, `goals_total_saved`, `goals_total_debt`) is pushed
 * from Dart via `HomeWidget.saveWidgetData` — see
 * `lib/core/home_widget/home_widget_service.dart`.
 */
class GoalsWidgetProvider : HomeWidgetProvider() {

  data class GoalLine(
      val name: String,
      val kind: String,
      val value: String,
      val percent: Int,
      val subtitle: String?,
  )

  private data class ItemViews(
      val itemId: Int,
      val nameId: Int,
      val valueId: Int,
      val progressId: Int,
      val subId: Int,
  )

  companion object {
    private val GOAL_SLOTS =
        listOf(
            ItemViews(
                itemId = R.id.widget_goal_item_1,
                nameId = R.id.widget_goal_name_1,
                valueId = R.id.widget_goal_value_1,
                progressId = R.id.widget_goal_progress_1,
                subId = R.id.widget_goal_sub_1,
            ),
            ItemViews(
                itemId = R.id.widget_goal_item_2,
                nameId = R.id.widget_goal_name_2,
                valueId = R.id.widget_goal_value_2,
                progressId = R.id.widget_goal_progress_2,
                subId = R.id.widget_goal_sub_2,
            ),
            ItemViews(
                itemId = R.id.widget_goal_item_3,
                nameId = R.id.widget_goal_name_3,
                valueId = R.id.widget_goal_value_3,
                progressId = R.id.widget_goal_progress_3,
                subId = R.id.widget_goal_sub_3,
            ),
        )

    private val LOAN_SLOTS =
        listOf(
            ItemViews(
                itemId = R.id.widget_loan_item_1,
                nameId = R.id.widget_loan_name_1,
                valueId = R.id.widget_loan_value_1,
                progressId = R.id.widget_loan_progress_1,
                subId = R.id.widget_loan_sub_1,
            ),
            ItemViews(
                itemId = R.id.widget_loan_item_2,
                nameId = R.id.widget_loan_name_2,
                valueId = R.id.widget_loan_value_2,
                progressId = R.id.widget_loan_progress_2,
                subId = R.id.widget_loan_sub_2,
            ),
        )
  }

  override fun onUpdate(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetIds: IntArray,
      widgetData: SharedPreferences,
  ) {
    val raw = widgetData.getString("goals_summary", null)
    val lines = parseLines(raw)
    val totalSaved = widgetData.getString("goals_total_saved", "Saved: ₹0")
    val totalDebt = widgetData.getString("goals_total_debt", "Debt: ₹0")

    val goals = lines.filter { it.kind.uppercase() == "GOAL" }
    val loans = lines.filter { it.kind.uppercase() == "LOAN" }

    appWidgetIds.forEach { widgetId ->
      val views =
          RemoteViews(context.packageName, R.layout.goals_widget).apply {
            val openGoals =
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("homewidget://goals"),
                )
            setOnClickPendingIntent(R.id.widget_root, openGoals)

            setTextViewText(R.id.widget_goals_total_saved, totalSaved)
            setTextViewText(R.id.widget_goals_total_debt, totalDebt)

            val isEmpty = goals.isEmpty() && loans.isEmpty()
            setViewVisibility(
                R.id.widget_goals_empty,
                if (isEmpty) View.VISIBLE else View.GONE,
            )

            // ── Goals Section ──
            if (goals.isNotEmpty()) {
              setViewVisibility(R.id.widget_section_goals, View.VISIBLE)
              setTextViewText(R.id.widget_goals_count, "(${goals.size})")

              GOAL_SLOTS.forEachIndexed { index, slot ->
                val goal = goals.getOrNull(index)
                if (goal == null) {
                  setViewVisibility(slot.itemId, View.GONE)
                } else {
                  setViewVisibility(slot.itemId, View.VISIBLE)
                  setTextViewText(slot.nameId, goal.name)
                  setTextViewText(slot.valueId, goal.value)
                  setProgressBar(slot.progressId, 100, goal.percent.coerceIn(0, 100), false)
                  if (!goal.subtitle.isNullOrEmpty()) {
                    setTextViewText(slot.subId, goal.subtitle)
                    setViewVisibility(slot.subId, View.VISIBLE)
                  } else {
                    setViewVisibility(slot.subId, View.GONE)
                  }
                }
              }
            } else {
              setViewVisibility(R.id.widget_section_goals, View.GONE)
            }

            // ── Loans Section ──
            if (loans.isNotEmpty()) {
              setViewVisibility(R.id.widget_section_loans, View.VISIBLE)
              setTextViewText(R.id.widget_loans_count, "(${loans.size})")

              LOAN_SLOTS.forEachIndexed { index, slot ->
                val loan = loans.getOrNull(index)
                if (loan == null) {
                  setViewVisibility(slot.itemId, View.GONE)
                } else {
                  setViewVisibility(slot.itemId, View.VISIBLE)
                  setTextViewText(slot.nameId, loan.name)
                  setTextViewText(slot.valueId, loan.value)
                  setProgressBar(slot.progressId, 100, loan.percent.coerceIn(0, 100), false)
                  if (!loan.subtitle.isNullOrEmpty()) {
                    setTextViewText(slot.subId, loan.subtitle)
                    setViewVisibility(slot.subId, View.VISIBLE)
                  } else {
                    setViewVisibility(slot.subId, View.GONE)
                  }
                }
              }
            } else {
              setViewVisibility(R.id.widget_section_loans, View.GONE)
            }
          }

      appWidgetManager.updateAppWidget(widgetId, views)
    }
  }

  private fun parseLines(raw: String?): List<GoalLine> {
    if (raw.isNullOrEmpty()) return emptyList()
    return try {
      val array = JSONArray(raw)
      (0 until array.length()).mapNotNull { i ->
        val obj = array.optJSONObject(i) ?: return@mapNotNull null
        val name = obj.optString("name", null) ?: return@mapNotNull null
        val kind = obj.optString("kind", "GOAL")
        val value = obj.optString("value", "")
        val percent = obj.optInt("percent", 0)
        val subtitle = obj.optString("subtitle", null)
        GoalLine(name, kind, value, percent, subtitle)
      }
    } catch (e: Exception) {
      emptyList()
    }
  }
}
