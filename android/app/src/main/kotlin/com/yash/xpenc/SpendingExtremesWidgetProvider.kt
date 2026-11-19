package com.yash.xpenc

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The home-screen "Spending Extremes" (Min & Max Spent) widget:
 * showcases the lowest and highest expense transactions for the current period
 * side-by-side with amount, date, category tag, and visual distribution indicators.
 *
 * Data (`extremes_min_amount`, `extremes_min_date`, `extremes_min_tag`, `extremes_min_id`,
 * `extremes_max_amount`, `extremes_max_date`, `extremes_max_tag`, `extremes_max_id`)
 * is pushed from Dart via `HomeWidget.saveWidgetData` — see
 * `lib/core/home_widget/home_widget_service.dart`.
 */
class SpendingExtremesWidgetProvider : HomeWidgetProvider() {

  override fun onUpdate(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetIds: IntArray,
      widgetData: SharedPreferences,
  ) {
    val minAmount = widgetData.getString("extremes_min_amount", null) ?: "--"
    val minDate = widgetData.getString("extremes_min_date", null) ?: "No expenses"
    val minTag = widgetData.getString("extremes_min_tag", null) ?: "# Expense"
    val minId = widgetData.getString("extremes_min_id", null)

    val maxAmount = widgetData.getString("extremes_max_amount", null) ?: "--"
    val maxDate = widgetData.getString("extremes_max_date", null) ?: "No expenses"
    val maxTag = widgetData.getString("extremes_max_tag", null) ?: "# Expense"
    val maxId = widgetData.getString("extremes_max_id", null)

    appWidgetIds.forEach { widgetId ->
      val views =
          RemoteViews(context.packageName, R.layout.spending_extremes_widget).apply {
            setTextViewText(R.id.widget_min_amount, minAmount)
            setTextViewText(R.id.widget_min_date, minDate)
            setTextViewText(R.id.widget_min_tag, minTag)

            setTextViewText(R.id.widget_max_amount, maxAmount)
            setTextViewText(R.id.widget_max_date, maxDate)
            setTextViewText(R.id.widget_max_tag, maxTag)

            // Click Min Spent card -> open that transaction or app
            val minIntent =
                if (!minId.isNullOrEmpty()) {
                  HomeWidgetLaunchIntent.getActivity(
                      context,
                      MainActivity::class.java,
                      Uri.parse("homewidget://tx?id=$minId"),
                  )
                } else {
                  HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
                }
            setOnClickPendingIntent(R.id.widget_min_card, minIntent)

            // Click Max Spent card -> open that transaction or app
            val maxIntent =
                if (!maxId.isNullOrEmpty()) {
                  HomeWidgetLaunchIntent.getActivity(
                      context,
                      MainActivity::class.java,
                      Uri.parse("homewidget://tx?id=$maxId"),
                  )
                } else {
                  HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
                }
            setOnClickPendingIntent(R.id.widget_max_card, maxIntent)

            // Click anywhere else -> open app
            val openApp = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
            setOnClickPendingIntent(R.id.widget_root, openApp)
          }

      appWidgetManager.updateAppWidget(widgetId, views)
    }
  }
}
