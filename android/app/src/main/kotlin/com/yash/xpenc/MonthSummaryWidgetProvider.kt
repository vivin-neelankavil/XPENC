package com.yash.xpenc

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The home-screen "This Month" widget: this calendar month's income and
 * expense totals side-by-side in styled cards, plus a net savings summary
 * and total savings banner at the bottom.
 *
 * Data (`month_income`, `month_expense`, `month_net_savings`, `month_total_savings`)
 * is pushed from Dart via `HomeWidget.saveWidgetData`, already formatted in
 * the user's chosen currency — see `lib/core/home_widget/home_widget_service.dart`.
 */
class MonthSummaryWidgetProvider : HomeWidgetProvider() {

  override fun onUpdate(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetIds: IntArray,
      widgetData: SharedPreferences,
  ) {
    val income = widgetData.getString("month_income", null) ?: "--"
    val expense = widgetData.getString("month_expense", null) ?: "--"
    val netSavings = widgetData.getString("month_net_savings", null) ?: "Total balance: --"
    val totalSavings = widgetData.getString("month_total_savings", null)

    appWidgetIds.forEach { widgetId ->
      val views =
          RemoteViews(context.packageName, R.layout.month_summary_widget).apply {
            setTextViewText(R.id.widget_month_income, income)
            setTextViewText(R.id.widget_month_expense, expense)
            setTextViewText(R.id.widget_month_net_savings, netSavings)

            if (!totalSavings.isNullOrEmpty()) {
              setTextViewText(R.id.widget_month_total_savings, totalSavings)
              setViewVisibility(R.id.widget_month_total_savings, View.VISIBLE)
            } else {
              setViewVisibility(R.id.widget_month_total_savings, View.GONE)
            }

            // Click "Money In" card -> open add transaction with income preselected
            val addIncome =
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("homewidget://add?type=income"),
                )
            setOnClickPendingIntent(R.id.widget_month_income_card, addIncome)
            setOnClickPendingIntent(R.id.widget_month_income, addIncome)
            setOnClickPendingIntent(R.id.widget_month_income_label, addIncome)

            // Click "Money Out" card -> open add transaction with expense preselected
            val addExpense =
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("homewidget://add?type=expense"),
                )
            setOnClickPendingIntent(R.id.widget_month_expense_card, addExpense)
            setOnClickPendingIntent(R.id.widget_month_expense, addExpense)
            setOnClickPendingIntent(R.id.widget_month_expense_label, addExpense)

            // Tapping anywhere else on the widget opens the app
            val openApp = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
            setOnClickPendingIntent(R.id.widget_root, openApp)
          }

      appWidgetManager.updateAppWidget(widgetId, views)
    }
  }
}
