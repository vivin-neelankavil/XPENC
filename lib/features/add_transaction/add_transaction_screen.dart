import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/app_icons.dart';
import '../../core/budget_cycle.dart';
import '../../core/layout/desktop.dart';
import '../../core/platform/stored_images.dart';
import '../../core/security/nct.dart';
import '../../core/currency.dart';
import '../../core/money.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/amount_keypad_field.dart';
import '../../core/widgets/app_surfaces.dart';
import '../../core/widgets/custom_icon_badge.dart';
import '../../core/widgets/icon_picker_sheet.dart';
import '../../core/widgets/money_text.dart';
import '../../data/currency_conversion.dart';
import '../../data/database.dart';
import '../../data/mode_providers.dart';
import '../../data/modes_db.dart';
import '../../data/providers.dart';
import '../../data/tables.dart';
import '../accounts/envelope_outflow.dart';
import '../payees/payee_picker_sheet.dart';
import '../persons/person_avatar.dart';
import '../settings/currency_picker_sheet.dart';
import '../tags/tag_picker_sheet.dart';
import 'amount_buffer.dart';
import 'date_time_combine.dart';
import 'receipt_storage.dart';
import '../../core/widgets/nav_bar_inset.dart';
import '../../core/l10n/l10n.dart';

/// One editable row of a split expense: which category, and how much of the
/// total it takes. Holds its own [AmountKeypadController] so its buffer text
/// (and which row is the shared keypad's current target — see
/// [_AddTransactionScreenState._activeAmountCtrl]) keeps its identity across
/// rebuilds.
class _SplitEntry {
  _SplitEntry({this.categoryId, Money? amount})
    : amountCtrl = AmountKeypadController() {
    if (amount != null) amountCtrl.setAmount(amount);
  }

  int? categoryId;
  final AmountKeypadController amountCtrl;

  Money get amount => amountCtrl.amount;

  void dispose() => amountCtrl.dispose();
}

/// One leg of a hybrid/split payment: which account, and how much of the
/// total it covers. Same shape as [_SplitEntry], but an account instead of
/// a category — see GitHub #43.
class _PaymentLegEntry {
  _PaymentLegEntry() : amountCtrl = AmountKeypadController();

  int? accountId;
  final AmountKeypadController amountCtrl;

  Money get amount => amountCtrl.amount;

  void dispose() => amountCtrl.dispose();
}

/// The ➕ route. Expense / Income / Transfer.
///
/// A transfer is neither income nor expense: it never carries a category and
/// always moves money between two different accounts.
///
/// With a [transactionId] the screen edits that existing transaction instead
/// of creating a new one.
///
/// With a [duplicateFromId] instead, every field is prefilled from that
/// transaction — same as editing — but [transactionId] stays null, so Save
/// creates a brand-new row rather than touching the source (GitHub #92:
/// "publish another one" of an existing transaction). The date resets to
/// today rather than copying the source's, nudging the user to notice this
/// is a separate entry and pick the date it actually happened on; the
/// receipt photo is never copied, since it's evidence of the original
/// purchase, not this new one.
///
/// With a [templateId] instead, fields are prefilled the same way from a
/// saved [TransactionTemplateRow] (GitHub #125) rather than a live
/// transaction — reached by picking a template from the ➕ button's choice
/// sheet. Same as duplicating: the date is always today, and there is no
/// receipt to carry over.
enum _AddScreenStep { operation, keypad }

enum _OperationTab { moneyIn, moneyOut, transfer }

class AddTransactionScreen extends ConsumerStatefulWidget {
  const AddTransactionScreen({
    this.transactionId,
    this.duplicateFromId,
    this.templateId,
    this.initialType,
    this.initialPayee,
    this.initialNote,
    this.initialAmount,
    this.initialAccountId,
    this.initialToAccountId,
    this.plannedCostId,
    this.initialDate,
    super.key,
  });

  final int? transactionId;

  /// Paying one of a mode's planned costs (see `ModePlannedCosts`): its
  /// amount, category and name come filled in, and saving marks it paid.
  final int? plannedCostId;
  final int? duplicateFromId;
  final int? templateId;

  /// Preselects Expense or Income — used by the home-screen widget's "+
  /// Expense" / "+ Income" shortcuts to skip the type-picker step. Ignored
  /// when [transactionId], [duplicateFromId] or [templateId] is set, since
  /// all three load their own type.
  final TxType? initialType;

  /// Prefills the payee/note/amount fields — used by the "Pay without
  /// internet" (*99#) flow to hand off what it already collected instead of
  /// making the user retype it. Ignored (like [initialType]) once
  /// [transactionId], [duplicateFromId] or [templateId] is set, since all
  /// three load their own values. All three are freely editable afterward,
  /// same as any other field on this screen.
  final String? initialPayee;
  final String? initialNote;
  final Money? initialAmount;

  /// Prefills the account (a transfer's "From") and a transfer's "To" — an
  /// account page's Transfer out / Transfer in (GitHub #171). Ignored like
  /// the fields above once an existing transaction is loaded.
  final int? initialAccountId;
  final int? initialToAccountId;

  /// Prefills the day — the calendar's ➕ for the day picked there. The
  /// time stays the current time, editable as usual. Ignored like the
  /// fields above once an existing transaction is loaded.
  final DateTime? initialDate;

  @override
  ConsumerState<AddTransactionScreen> createState() =>
      _AddTransactionScreenState();
}

class _AddTransactionScreenState extends ConsumerState<AddTransactionScreen> {
  late TxType _type;
  _AddScreenStep _step = _AddScreenStep.operation;
  _OperationTab _operationTab = _OperationTab.moneyOut;
  String _calcBuffer = '';
  double? _firstOperand;
  String? _pendingOperator;

  /// The main amount's buffer — same [AmountKeypadController] used for every
  /// other money field on this screen, so a prefilled edit value ("15.44")
  /// is replaced wholesale by the first keypad tap instead of appended to
  /// (see GitHub #45; the `freshEntry` contract now lives on the controller).
  final _mainAmountCtrl = AmountKeypadController();

  /// Which money field the single shared keypad (see [_buildKeypad]) is
  /// currently editing — the main amount, a split row, a hybrid leg, or the
  /// foreign/change amount. Tapping any amount field's display box makes it
  /// the target; defaults to the main amount.
  late AmountKeypadController _activeAmountCtrl;

  int? _accountId; // expense/income: account. transfer: FROM account.
  int? _toAccountId; // transfer: TO account.
  int? _categoryId; // income/expense only.
  DateTime _date = DateTime.now();

  final _noteController = TextEditingController();
  final _noteFocus = FocusNode();

  /// Expense only — who got paid. Free text with autocomplete, never read for
  /// any other transaction type.
  final _payeeController = TextEditingController();

  /// Set when the payee is one of the user's people (picked in the payee
  /// sheet) — a label only, never owe/due. Cleared with the payee.
  int? _payeePersonId;

  /// Cuts across category/account — any transaction type can carry tags.
  Set<int> _tagIds = {};

  /// Expense only — one expense, several categories, instead of one.
  bool _isSplit = false;
  final List<_SplitEntry> _splitRows = [];

  /// Expense only — one expense, several *accounts*, instead of one (see
  /// GitHub #43). Mutually exclusive with [_isSplit] — combining both is a
  /// 2-D matrix this screen doesn't offer. Creation only: editing an
  /// existing hybrid payment's legs together isn't supported here, since
  /// each leg is its own transaction row, not sub-rows of one — see
  /// `AppDatabase.addHybridPaymentTransaction`.
  bool _isHybridPayment = false;
  final List<_PaymentLegEntry> _hybridLegs = [];

  /// Expense only, paid from a cash account — some of the change received
  /// lands in a different account instead of back in the paying one (e.g.
  /// coins into a separate "Coins" account) — see GitHub #55. Mutually
  /// exclusive with [_isSplit] / [_isHybridPayment], same reasoning as those.
  /// Creation only, same reasoning as [_isHybridPayment].
  bool _hasChange = false;
  int? _changeAccountId;
  final _changeAmountCtrl = AmountKeypadController();

  /// Income/expense only — "this was originally paid in another currency"
  /// (GitHub #85), purely informational: [_amount] stays what actually moved
  /// through the account. Unlike hybrid payment/change, this can be edited
  /// after the fact, so it isn't gated on `!_isEditing`. Mutually exclusive
  /// with hybrid payment and change (same toggle group); coexists with
  /// split, since a split doesn't touch the transaction's own amount/currency.
  bool _hasForeignCurrency = false;
  String? _foreignCurrencyCode;
  final _foreignAmountCtrl = AmountKeypadController();

  /// The receipt path that will be saved — an existing one loaded for
  /// editing, a freshly picked one, or null.
  String? _imagePath;

  /// Set only when [_imagePath] was picked *this session* and not yet saved —
  /// so `dispose()` can clean it up if the screen is left without saving,
  /// rather than leaking a copy nothing will ever reference.
  String? _unsavedPickedPath;

  /// A per-transaction visual marker independent of [_categoryId] — see the
  /// doc on `Transactions.customIcon` for its two encodings. Cuts across
  /// category/account/type, same as [_tagIds]; null means none picked.
  String? _customIcon;

  /// NCT — non-capturable (GitHub #143): frosted wherever it's listed,
  /// captures blocked while it's open. See `lib/core/security/nct.dart`.
  bool _isNct = false;

  /// The mode (a trip) this transaction is in, or would join — see
  /// `Transactions.modeId`. A new one joins whichever mode is ON; an edited
  /// one shows its own (or the ON one, to move it in). [_inMode] is the
  /// "Part of …" switch.
  ModeRow? _mode;
  bool _inMode = false;

  /// The foreign amount was opened by the mode's currency, not by hand —
  /// left empty, the transaction simply has none.
  bool _foreignFromMode = false;

  /// The mode the pickers limit themselves to.
  int? get _pickerModeId => _inMode ? _mode?.id : null;

  /// The mode's people this expense is split with — equal shares, you paid
  /// (see `_splitsWithPeople`). Empty = not split.
  Set<int> _splitWith = {};

  bool get _splitsWithPeople =>
      _splitWith.isNotEmpty &&
      _inMode &&
      _mode?.groupId != null &&
      _type == TxType.expense &&
      !_isEditing &&
      !_isSplitting &&
      !_isHybrid &&
      !_isChange;

  /// True while an existing transaction is being fetched for editing.
  bool _loading = false;

  bool get _isEditing => widget.transactionId != null;

  /// Split only ever applies to an expense — [_isSplit] can be stale after a
  /// type switch (kept around so toggling back doesn't lose entered rows).
  bool get _isSplitting => _type == TxType.expense && _isSplit;

  /// Hybrid payment only ever applies to a brand-new expense — see the doc
  /// on [_isHybridPayment].
  bool get _isHybrid =>
      _type == TxType.expense && !_isEditing && _isHybridPayment;

  /// Change only ever applies to a brand-new cash expense — see the doc on
  /// [_hasChange]. Re-checks the account's type (not just [_hasChange])
  /// so switching "Paid via" away from a cash account hides the editor
  /// along with the toggle, instead of leaving it stranded on screen —
  /// [_hasChange] itself is left untouched, same reasoning as [_isSplitting]
  /// staying stale-but-harmless across a type switch.
  bool get _isChange =>
      _type == TxType.expense &&
      !_isEditing &&
      _hasChange &&
      ref.read(accountMapProvider)[_accountId]?.type == AccountType.cash;

  Money get _changeAmount => _changeAmountCtrl.amount;

  /// Foreign currency only ever applies to an income or expense — a transfer
  /// moves money between the user's own accounts, with nothing "paid" in
  /// another currency.
  bool get _isForeignCurrency =>
      (_type == TxType.income || _type == TxType.expense) &&
      _hasForeignCurrency;

  Money get _foreignAmount => _foreignAmountCtrl.amount;

  /// The custom keypad and the system keyboard must never both be up — they'd
  /// fight over the same strip of screen and hide whatever the user just
  /// typed. Every money field on this screen (main amount, split rows,
  /// hybrid legs, foreign, change) now shares the same in-app keypad instead
  /// of the OS keyboard (see GitHub #135), so the only real `TextField`s left
  /// here is Note (Payee is picked in its own sheet) — the keypad only hides
  /// while it has focus.
  bool get _textFieldFocused => _noteFocus.hasFocus;

  /// Laid out for a PC (see [DesktopLayout]) as of the last build: the
  /// keyboard types the amount, and the on-screen keypad stays hidden.
  bool _desktop = false;

  /// A PC's keyboard does what the keypad does — digits and `.` into the
  /// amount being edited, Backspace — plus Enter to save and Esc to close.
  /// Not while Note has the keyboard, nor under a picker opened over this.
  bool _onHardwareKey(KeyEvent event) {
    if (!_desktop || !mounted || event is KeyUpEvent || _textFieldFocused) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    final char = event.character;
    if (char != null && RegExp(r'^[0-9.]$').hasMatch(char)) {
      _onKey(char);
      return true;
    }
    if (key == LogicalKeyboardKey.backspace) {
      _onBackspace();
      return true;
    }
    if (event is KeyRepeatEvent) return false;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _save();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    _activeAmountCtrl = _mainAmountCtrl;
    // Only expense/income/transfer are ever meaningful here — anything else
    // (or nothing) falls back to the screen's own default.
    final initial = widget.initialType;
    _type =
        (!_isEditing &&
            (initial == TxType.expense ||
                initial == TxType.income ||
                initial == TxType.transfer))
        ? initial!
        : TxType.expense;

    if (_type == TxType.income) {
      _operationTab = _OperationTab.moneyIn;
    } else if (_type == TxType.transfer) {
      _operationTab = _OperationTab.transfer;
    } else {
      _operationTab = _OperationTab.moneyOut;
    }

    _step = (_isEditing ||
            widget.duplicateFromId != null ||
            widget.templateId != null ||
            widget.plannedCostId != null ||
            widget.initialAmount != null ||
            widget.initialAccountId != null ||
            widget.initialToAccountId != null ||
            widget.initialType != null)
        ? _AddScreenStep.keypad
        : _AddScreenStep.operation;
    _noteFocus.addListener(_onFieldFocusChanged);
    if (_isEditing) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadForEdit());
    } else if (widget.duplicateFromId != null) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _loadForDuplicate();
        await _seedMode();
      });
    } else if (widget.templateId != null) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _loadForTemplate();
        await _seedMode();
      });
    } else {
      if (widget.initialPayee != null) {
        _payeeController.text = widget.initialPayee!;
      }
      if (widget.initialNote != null) {
        _noteController.text = widget.initialNote!;
      }
      if (widget.initialAmount != null) {
        _mainAmountCtrl.setAmount(widget.initialAmount!);
      }
      if (widget.initialDate != null) {
        _date = combineDateAndTime(widget.initialDate!, TimeOfDay.now());
      }
      _accountId = widget.initialAccountId;
      if (_type == TxType.transfer) _toAccountId = widget.initialToAccountId;
      // Pre-select the last-used account on a brand-new transaction, once the
      // one-shot query resolves. Still freely changeable via "Paid via", and
      // the guard on `_accountId` below means it never overwrites a
      // selection the user already made while this was loading.
      _seedLastUsedAccount();
      // Paying a planned cost joins that cost's mode, ON or not.
      if (widget.plannedCostId != null) {
        _loadPlannedCost();
      } else {
        _seedMode();
      }
    }
  }

  /// Fills in the planned cost being paid.
  Future<void> _loadPlannedCost() async {
    final db = ref.read(dbProvider);
    final cost = await (db.select(
      db.modePlannedCosts,
    )..where((c) => c.id.equals(widget.plannedCostId!))).getSingleOrNull();
    if (!mounted || cost == null) return;
    setState(() {
      _type = TxType.expense;
      _mainAmountCtrl.setAmount(cost.amount);
      _categoryId = cost.categoryId ?? _categoryId;
      if (_noteController.text.isEmpty) _noteController.text = cost.name;
    });
    await _seedMode(modeId: cost.modeId);
  }

  /// Over one of the mode's limits? Ask first — going over is the person's
  /// call, so this never refuses on its own.
  Future<bool> _withinModeLimits(Money amount) async {
    final mode = _mode;
    if (!_inMode ||
        mode == null ||
        _type != TxType.expense ||
        !amount.isPositive) {
      return true;
    }
    // A split counts only your own share as spent.
    final mine = _splitsWithPeople
        ? Money(amount.paise ~/ (_splitWith.length + 1))
        : amount;
    final warnings = await ref
        .read(dbProvider)
        .modeLimitWarnings(
          modeId: mode.id,
          amount: mine,
          categoryId: _isSplitting ? null : _categoryId,
          accountId: _isHybrid ? null : _accountId,
          date: _date,
          excludeTxId: widget.transactionId,
          plannedCostId: widget.plannedCostId,
        );
    if (warnings.isEmpty || !mounted) return true;
    final go = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Over {0}’s limits', [mode.name])),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final w in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• $w'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Tr('Change'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Tr('Save anyway'),
          ),
        ],
      ),
    );
    return go == true;
  }

  /// A new transaction joins the mode that's ON: its auto-tags come
  /// pre-picked, a limited mode starts on one of its accounts and, abroad,
  /// its currency opens the foreign amount.
  Future<void> _seedMode({int? modeId}) async {
    final db = ref.read(dbProvider);
    final id = modeId ?? await db.activeModeId();
    if (id == null) return;
    final mode = await db.modeById(id);
    final autoTags = await db.modeTagIds(id);
    final allowed = await db.modeAccountIds(id);
    if (!mounted || mode == null) return;
    setState(() {
      _mode = mode;
      _inMode = true;
      _tagIds = {..._tagIds, ...autoTags};
      // An account the person came from (an account page's Transfer out)
      // is their pick — the mode doesn't swap it.
      if (widget.initialAccountId == null &&
          allowed.isNotEmpty &&
          (_accountId == null || !allowed.contains(_accountId))) {
        _accountId = allowed.first;
      }
      final code = mode.currencyCode;
      if (code != null &&
          code != MoneyFormat.currency.code &&
          !_hasForeignCurrency) {
        _hasForeignCurrency = true;
        _foreignFromMode = true;
        _foreignCurrencyCode = code;
      }
    });
  }

  /// An edited transaction shows its own mode — or, when it's in none, the
  /// one that's ON, so it can be moved in.
  Future<void> _loadEditMode(int? modeId) async {
    final db = ref.read(dbProvider);
    final id = modeId ?? await db.activeModeId();
    if (id == null) return;
    final mode = await db.modeById(id);
    if (!mounted || mode == null) return;
    setState(() {
      _mode = mode;
      _inMode = modeId != null;
    });
  }

  Future<void> _seedLastUsedAccount() async {
    final txs = await ref.read(dbProvider).watchTransactions(limit: 1).first;
    if (!mounted || _accountId != null || txs.isEmpty) return;
    // A transfer can't leave from the account it's going to.
    if (txs.first.accountId == _toAccountId) return;
    setState(() => _accountId = txs.first.accountId);
  }

  void _ensureDefaultAccount() {
    if (_accountId != null) return;
    final accounts = ref.read(accountsProvider).valueOrNull ?? [];
    if (accounts.isNotEmpty) {
      _accountId = accounts.first.id;
    }
  }

  void _onFieldFocusChanged() => setState(() {});

  static void _deleteQuietly(String path) {
    StoredImages.delete(path).ignore();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _noteController.dispose();
    _noteFocus.dispose();
    _payeeController.dispose();
    for (final row in _splitRows) {
      row.dispose();
    }
    for (final leg in _hybridLegs) {
      leg.dispose();
    }
    _mainAmountCtrl.dispose();
    _changeAmountCtrl.dispose();
    _foreignAmountCtrl.dispose();
    // Best-effort: leaving without saving shouldn't leak the copy made on
    // pick. Fire-and-forget — nothing in this widget survives to await it.
    if (_unsavedPickedPath != null) _deleteQuietly(_unsavedPickedPath!);
    super.dispose();
  }

  /// Fetch the row being edited and prefill every field from it.
  Future<void> _loadForEdit() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final db = ref.read(dbProvider);
    final row = await db.transactionById(widget.transactionId!);
    final tagIds = await db.tagIdsForTransaction(widget.transactionId!);
    final splits = await db.splitsForTransaction(widget.transactionId!);
    if (!mounted) return;

    if (row == null) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Tr('Transaction not found')),
      );
      return;
    }

    // This screen only offers Expense / Income / Transfer. A person movement
    // has no segment, and `SegmentedButton` asserts that its selected value is
    // one of its segments — assigning it here would crash the screen. A
    // repayment marked to count as income reads as ordinary `TxType.income`,
    // so it needs its own check — see `isPersonLinkedTransaction`.
    final isPersonLinked =
        row.type.isPersonMovement ||
        (row.type.isIncomeOrExpense &&
            await db.isPersonLinkedTransaction(row.id));
    if (!mounted) return;
    if (isPersonLinked) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Tr('Edit this from the person\'s page.')),
      );
      return;
    }

    setState(() {
      _type = row.type;
      _mainAmountCtrl.setAmount(row.amount);
      _accountId = row.accountId;
      _toAccountId = row.toAccountId;
      _categoryId = row.categoryId;
      _date = row.date;
      _noteController.text = row.note ?? '';
      _payeeController.text = row.payee ?? '';
      _payeePersonId = row.type.isIncomeOrExpense ? row.personId : null;
      _tagIds = tagIds.toSet();
      _imagePath = row.imagePath;
      _customIcon = row.customIcon;
      _isNct = row.isNct;
      _isSplit = splits.isNotEmpty;
      for (final s in splits) {
        _splitRows.add(_SplitEntry(categoryId: s.categoryId, amount: s.amount));
      }
      _hasForeignCurrency = row.foreignAmount != null;
      _foreignCurrencyCode = row.foreignCurrencyCode;
      if (row.foreignAmount != null) {
        _foreignAmountCtrl.setAmount(row.foreignAmount!);
      }
      _loading = false;
    });
    await _loadEditMode(row.modeId);
  }

  /// Fetch the transaction being duplicated and prefill every field from it,
  /// same as [_loadForEdit] — except [_date] resets to today instead of
  /// copying the source's, and the receipt (if any) is never carried over.
  /// [widget.transactionId] stays null throughout, so `_save` inserts a new
  /// row instead of updating the source.
  Future<void> _loadForDuplicate() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final db = ref.read(dbProvider);
    final sourceId = widget.duplicateFromId!;
    final row = await db.transactionById(sourceId);
    final tagIds = await db.tagIdsForTransaction(sourceId);
    final splits = await db.splitsForTransaction(sourceId);
    if (!mounted) return;

    if (row == null) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Tr('Transaction not found')),
      );
      return;
    }

    // Same restriction as `_loadForEdit`: this screen has no shape for a
    // person movement (or a repayment counted as income), so there is
    // nothing sensible to prefill it into.
    final isPersonLinked =
        row.type.isPersonMovement ||
        (row.type.isIncomeOrExpense &&
            await db.isPersonLinkedTransaction(row.id));
    if (!mounted) return;
    if (isPersonLinked) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Tr("This can't be duplicated from here.")),
      );
      return;
    }

    setState(() {
      _type = row.type;
      _mainAmountCtrl.setAmount(row.amount);
      _accountId = row.accountId;
      _toAccountId = row.toAccountId;
      _categoryId = row.categoryId;
      _noteController.text = row.note ?? '';
      _payeeController.text = row.payee ?? '';
      _payeePersonId = row.type.isIncomeOrExpense ? row.personId : null;
      _tagIds = tagIds.toSet();
      _customIcon = row.customIcon;
      _isNct = row.isNct;
      _isSplit = splits.isNotEmpty;
      for (final s in splits) {
        _splitRows.add(_SplitEntry(categoryId: s.categoryId, amount: s.amount));
      }
      _hasForeignCurrency = row.foreignAmount != null;
      _foreignCurrencyCode = row.foreignCurrencyCode;
      if (row.foreignAmount != null) {
        _foreignAmountCtrl.setAmount(row.foreignAmount!);
      }
      _loading = false;
    });
  }

  /// Fetch the saved template and prefill every field it carries — same
  /// shape as [_loadForDuplicate], minus splits and foreign currency, which
  /// no [TransactionTemplateRow] stores (see its own doc comment).
  /// [widget.transactionId] stays null throughout, so `_save` inserts a new
  /// row rather than touching anything.
  Future<void> _loadForTemplate() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final db = ref.read(dbProvider);
    final row = await db.transactionTemplateById(widget.templateId!);
    if (!mounted) return;

    if (row == null) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Tr('Template not found')),
      );
      return;
    }

    final tagIds = await db.tagIdsForTemplate(widget.templateId!);
    if (!mounted) return;

    setState(() {
      _type = row.type;
      _mainAmountCtrl.setAmount(row.amount);
      _accountId = row.accountId;
      _toAccountId = row.toAccountId;
      _categoryId = row.categoryId;
      _noteController.text = row.note ?? '';
      _payeeController.text = row.payee ?? '';
      _tagIds = tagIds.toSet();
      _loading = false;
    });
  }

  /// The live main amount. Tolerates a trailing dot while the user is
  /// mid-type.
  Money get _amount => _mainAmountCtrl.amount;

  // ── Keypad ────────────────────────────────────────────────────────────────

  /// Makes [ctrl] the shared keypad's target and brings the keypad back if
  /// Note/Payee had stolen focus — every amount field's display box calls
  /// this on tap.
  void _activateAmountCtrl(AmountKeypadController ctrl) {
    FocusScope.of(context).unfocus();
    setState(() => _activeAmountCtrl = ctrl);
  }

  void _onKey(String k) => setState(() {
    _activeAmountCtrl.applyKey(k);
    _afterAmountTyped();
  });

  void _onBackspace() => setState(() {
    _activeAmountCtrl.applyBackspace();
    _afterAmountTyped();
  });

  void _onCalcDigit(String digit) {
    if (!identical(_activeAmountCtrl, _mainAmountCtrl)) {
      _onKey(digit);
      return;
    }
    setState(() {
      _calcBuffer = AmountBuffer.applyKey(_calcBuffer, digit);
      final parsed = double.tryParse(_calcBuffer) ?? 0.0;
      _mainAmountCtrl.setAmount(Money.fromRupees(parsed));
      _afterAmountTyped();
    });
  }

  void _onCalcOperator(String op) {
    if (!identical(_activeAmountCtrl, _mainAmountCtrl)) return;
    setState(() {
      if (_calcBuffer.isEmpty && _pendingOperator != null) {
        _pendingOperator = op;
        return;
      }
      final currentVal = _calcBuffer.isNotEmpty
          ? (double.tryParse(_calcBuffer) ?? 0.0)
          : (_mainAmountCtrl.amount.paise / 100.0);
      if (_firstOperand == null) {
        _firstOperand = currentVal;
      } else if (_pendingOperator != null) {
        switch (_pendingOperator) {
          case '+':
            _firstOperand = _firstOperand! + currentVal;
            break;
          case '-':
            _firstOperand = _firstOperand! - currentVal;
            break;
          case '×':
            _firstOperand = _firstOperand! * currentVal;
            break;
          case '÷':
            _firstOperand = currentVal != 0 ? _firstOperand! / currentVal : _firstOperand!;
            break;
        }
      }
      _pendingOperator = op;
      _calcBuffer = '';
      _mainAmountCtrl.setAmount(Money.fromRupees(_firstOperand!));
      _afterAmountTyped();
    });
  }

  void _onCalcBackspace() {
    if (!identical(_activeAmountCtrl, _mainAmountCtrl)) {
      _onBackspace();
      return;
    }
    setState(() {
      if (_calcBuffer.isNotEmpty) {
        _calcBuffer = AmountBuffer.applyBackspace(_calcBuffer);
        final parsed = double.tryParse(_calcBuffer) ?? 0.0;
        _mainAmountCtrl.setAmount(Money.fromRupees(parsed));
        _afterAmountTyped();
      } else if (_pendingOperator != null) {
        _pendingOperator = null;
        if (_firstOperand != null) {
          _calcBuffer = _firstOperand! % 1 == 0
              ? _firstOperand!.toInt().toString()
              : _firstOperand!.toString();
          _firstOperand = null;
        }
      } else {
        _onBackspace();
      }
    });
  }

  void _onCalcCurrency() {
    if (!identical(_activeAmountCtrl, _mainAmountCtrl)) return;
    setState(() {
      if (_calcBuffer.isNotEmpty && !_calcBuffer.contains('.')) {
        _calcBuffer = '${_calcBuffer}00';
        final parsed = double.tryParse(_calcBuffer) ?? 0.0;
        _mainAmountCtrl.setAmount(Money.fromRupees(parsed));
        _afterAmountTyped();
      }
    });
  }

  void _onCalcSubmit() {
    if (_pendingOperator != null && _calcBuffer.isNotEmpty) {
      final currentVal = double.tryParse(_calcBuffer) ?? 0.0;
      switch (_pendingOperator) {
        case '+':
          _firstOperand = (_firstOperand ?? 0.0) + currentVal;
          break;
        case '-':
          _firstOperand = (_firstOperand ?? 0.0) - currentVal;
          break;
        case '×':
          _firstOperand = (_firstOperand ?? 0.0) * currentVal;
          break;
        case '÷':
          _firstOperand = currentVal != 0 ? (_firstOperand ?? 0.0) / currentVal : _firstOperand;
          break;
      }
      _mainAmountCtrl.setAmount(Money.fromRupees(_firstOperand ?? 0.0));
      _pendingOperator = null;
      _firstOperand = null;
      _calcBuffer = '';
    }
    _save();
  }

  String _formatAmountDisplay(Money amount, Currency? txCurrency) {
    final currencySymbol = txCurrency?.symbol ?? '₹';
    if (_pendingOperator != null) {
      final firstStr = _firstOperand != null
          ? (_firstOperand! % 1 == 0 ? _firstOperand!.toInt().toString() : _firstOperand!.toStringAsFixed(2))
          : '0';
      final secondStr = _calcBuffer.isEmpty ? '' : _calcBuffer;
      return '$firstStr $_pendingOperator $secondStr $currencySymbol'.trim();
    }
    return txCurrency == null
        ? MoneyFormat.symbol(amount)
        : MoneyFormat.symbolIn(amount, txCurrency);
  }

  void _afterAmountTyped() {
    if (identical(_activeAmountCtrl, _foreignAmountCtrl)) {
      _fillAmountFromForeign();
    } else if (identical(_activeAmountCtrl, _mainAmountCtrl)) {
      _amountFromRate = false;
    }
  }

  /// Whether the main amount was last written by [_fillAmountFromForeign]
  /// rather than typed — only then may clearing the foreign amount clear it.
  bool _amountFromRate = false;

  /// The latest Settings › Currencies rate for the picked foreign currency,
  /// or null when none has been saved (or rates haven't loaded yet).
  int? get _foreignRate {
    final code = _foreignCurrencyCode;
    if (code == null) return null;
    for (final r in ref.read(currencyRatesProvider).valueOrNull ?? const []) {
      if (r.currencyCode == code) return r.rateToBaseMicros;
    }
    return null;
  }

  /// With a saved rate, the foreign amount fills in the main amount, as it's
  /// typed and when its currency changes (GitHub #195 — the rate saved in
  /// Settings was never used here, so the amount kept whatever was typed).
  /// Typing the main amount afterwards still wins: what the card was really
  /// charged is the truth, and the line under the editor shows the rate
  /// that implies.
  void _fillAmountFromForeign() {
    if (!_isForeignCurrency) return;
    final rate = _foreignRate;
    if (rate == null) return;
    final foreign = _foreignAmount;
    if (foreign.isPositive) {
      _mainAmountCtrl.setAmount(convertUsingRate(foreign, rate));
      _amountFromRate = true;
    } else if (_amountFromRate) {
      _mainAmountCtrl.text = '';
    }
  }

  // ── Pickers ───────────────────────────────────────────────────────────────

  Future<void> _pickAccount({required bool isFrom}) async {
    final forTo = _type == TxType.transfer && !isFrom;
    final selected = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AccountPickerSheet(
        title: forTo
            ? tr('To account')
            : (_type == TxType.transfer ? tr('From account') : tr('Account')),
        excludeId: forTo ? _accountId : null,
        // A mode's account limit is about what it pays with — a transfer
        // can still land anywhere.
        modeId: forTo ? null : _pickerModeId,
        // A goal isn't a spendable account — it's only funded or drawn down
        // by a transfer — unless its "Show in Money in / out" is on (#173).
        excludeGoals: _type != TxType.transfer,
        moneyInOut: _type.isIncomeOrExpense,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (forTo) {
        _toAccountId = selected;
      } else {
        _accountId = selected;
        if (_toAccountId == selected) _toAccountId = null;
      }
    });
  }

  Future<void> _pickCategory() async {
    final kind = _type == TxType.income
        ? CategoryKind.income
        : CategoryKind.expense;
    final current = ref.read(categoryMapProvider)[_categoryId];
    final selected = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CategoryPickerSheet(
        kind: kind,
        envelopeAccountId: _envelopeAccountId,
        modeId: _pickerModeId,
        // Money in can be a refund to a spending category (GitHub #201).
        startAsRefund:
            kind == CategoryKind.income &&
            current?.kind == CategoryKind.expense,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _categoryId = selected);
  }

  /// The currency [accountId] actually posts in — null for the parent
  /// currency, same "null means parent" convention as
  /// [AccountRow.currencyCode] itself. A debit/UPI instrument has no
  /// currency of its own (see `tables.dart`'s doc on `Accounts.currencyCode`)
  /// so this follows [AccountRow.linkedAccountId] once to the account that
  /// actually holds the money.
  Currency? _currencyForAccount(
    int? accountId,
    Map<int, AccountRow> accountMap,
  ) {
    final account = accountMap[accountId];
    if (account == null) return null;
    final code = account.linkedAccountId == null
        ? account.currencyCode
        : accountMap[account.linkedAccountId]?.currencyCode;
    return code == null ? null : currencyForCode(code);
  }

  /// An informational "≈ X received" line for a transfer between two
  /// accounts that don't share a currency — read-only, purely a preview of
  /// what `AppDatabase.addTransaction` will itself compute and store as
  /// `toAmount` at save time (see its `_resolveTxCurrency`/cross-currency
  /// logic), using whatever rate is current right now. `null` whenever
  /// there's nothing to preview: not a transfer, no destination picked yet,
  /// both legs share a currency, the amount is still zero, or a needed rate
  /// hasn't loaded/been entered yet — the save button itself is the one
  /// source of truth for whether posting will actually succeed.
  Widget? _crossCurrencyTransferPreview(Map<int, AccountRow> accountMap) {
    if (_type != TxType.transfer || _toAccountId == null) return null;
    final sourceCurrency = _currencyForAccount(_accountId, accountMap);
    final destCurrency = _currencyForAccount(_toAccountId, accountMap);
    if (sourceCurrency?.code == destCurrency?.code) return null;

    final amount = _amount;
    if (!amount.isPositive) return null;

    final rates = ref.watch(currencyRatesProvider).valueOrNull;
    if (rates == null) return null;
    final rateFor = {for (final r in rates) r.currencyCode: r.rateToBaseMicros};

    Money sourceBase;
    if (sourceCurrency == null) {
      sourceBase = amount;
    } else {
      final rate = rateFor[sourceCurrency.code];
      if (rate == null) return null;
      sourceBase = convertUsingRate(amount, rate);
    }

    Money destAmount;
    if (destCurrency == null) {
      destAmount = sourceBase;
    } else {
      final rate = rateFor[destCurrency.code];
      if (rate == null) return null;
      destAmount = Money((sourceBase.paise * currencyRateScale) ~/ rate);
    }

    final theme = Theme.of(context);
    final formatted = destCurrency == null
        ? MoneyFormat.symbol(destAmount)
        : MoneyFormat.symbolIn(destAmount, destCurrency);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        tr('≈ {0} received, at today\'s rate', [formatted]),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// A small note when this expense/transfer would take its source account
  /// below the floor set on [AccountRow.minimumBalance] — purely
  /// informational, never blocks Save (see the doc on that column). Creation
  /// only: an existing transaction's amount has already been applied to
  /// [AccountRow.currentBalance] once, so re-subtracting it here would
  /// double-count and could warn (or fail to warn) wrongly.
  Widget? _minimumBalanceWarning(Map<int, AccountRow> accountMap) {
    if (_isEditing) return null;
    if (_type != TxType.expense && _type != TxType.transfer) return null;
    final account = accountMap[_accountId];
    final minimumBalance = account?.minimumBalance;
    if (account == null || minimumBalance == null) return null;
    final amount = _amount;
    if (!amount.isPositive) return null;

    final projected = account.currentBalance - amount;
    if (!(projected < minimumBalance)) return null;

    final theme = Theme.of(context);
    final currency = _currencyForAccount(_accountId, accountMap);
    final formattedMin = currency == null
        ? MoneyFormat.symbol(minimumBalance)
        : MoneyFormat.symbolIn(minimumBalance, currency);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(
            Icons.warning_amber_rounded,
            size: 16,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              tr('This takes {0} below your minimum balance of '
              '{1}.', [account.name, formattedMin]),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Non-null only for an expense on an Envelope Mode account — the signal
  /// [_CategoryPickerSheet] uses to show each category's remaining balance
  /// inline instead of just its name.
  int? get _envelopeAccountId {
    if (_type != TxType.expense || _accountId == null) return null;
    final account = ref.read(accountMapProvider)[_accountId];
    return (account?.envelopeMode ?? false) ? _accountId : null;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(
      () => _date = combineDateAndTime(picked, TimeOfDay.fromDateTime(_date)),
    );
  }

  /// Optional — most transactions never need this touched at all. Lets
  /// someone correct the exact time when they log an expense later than it
  /// actually happened (GitHub #124), without needing to re-pick the date.
  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (picked == null || !mounted) return;
    setState(() => _date = combineDateAndTime(_date, picked));
  }

  // ── Custom icon / emoji ──────────────────────────────────────────────────


  Future<void> _pickCustomIcon() async {
    final choice = await showAppSheet<_CustomIconSource>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppListTile(
              leading: const AppIcon(Icons.grid_view_rounded),
              title: const Tr('XPENC icon'),
              subtitle: const Tr('Pick from the app\'s own icon library'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_CustomIconSource.library),
            ),
            AppListTile(
              leading: const AppIcon(Icons.emoji_emotions_outlined),
              title: const Tr('Emoji'),
              subtitle: const Tr('Type one with your keyboard\'s emoji key'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_CustomIconSource.emoji),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == _CustomIconSource.library) {
      final key = await showIconPickerSheet(
        context,
        selected: _customIcon == null
            ? null
            : CustomIconBadge.iconKeyOf(_customIcon!),
      );
      if (key == null || !mounted) return;
      setState(() => _customIcon = CustomIconBadge.encodeIconKey(key));
    } else {
      final emoji = await _pickEmoji();
      if (emoji == null || emoji.isEmpty || !mounted) return;
      setState(() => _customIcon = emoji);
    }
  }

  Future<String?> _pickEmoji() {
    final current = _customIcon;
    return showEmojiInputSheet(
      context,
      initial: (current != null && !CustomIconBadge.isIconKey(current))
          ? current
          : '',
    );
  }

  Future<void> _openCustomIconSheet() async {
    final value = _customIcon;
    if (value == null) return;
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomIconBadge(value: value, size: 64),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _pickCustomIcon();
                      },
                      icon: const AppIcon(Icons.swap_horiz_rounded),
                      label: const Tr('Change'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.expense,
                      ),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        setState(() => _customIcon = null);
                      },
                      icon: const AppIcon(Icons.delete_outline),
                      label: const Tr('Remove'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Receipt photo ────────────────────────────────────────────────────────

  /// Two ways onto [_pickReceipt]: the camera (needs the `CAMERA` permission,
  /// see PRIVACY.md) or the existing permission-free gallery/file picker.
  Future<void> _showAttachReceiptSheet() async {
    final source = await showAppSheet<_ReceiptSource>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppListTile(
              leading: const AppIcon(Icons.photo_camera_outlined),
              title: const Tr('Take photo'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_ReceiptSource.camera),
            ),
            AppListTile(
              leading: const AppIcon(Icons.photo_library_outlined),
              title: const Tr('Choose from gallery'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_ReceiptSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    await _pickReceipt(source);
  }

  Future<void> _pickReceipt(_ReceiptSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    String? path;
    try {
      path = source == _ReceiptSource.camera
          ? await ReceiptStorage.pickFromCamera()
          : await ReceiptStorage.pickAndStore();
    } catch (_) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Tr(
              "Couldn't open the camera — check its permission in system "
              'settings.',
            ),
          ),
        );
      return;
    }
    if (path == null || !mounted) return;
    // Replacing an already-picked-this-session file before ever saving —
    // that earlier copy is now unreferenced.
    final previous = _unsavedPickedPath;
    setState(() {
      _imagePath = path;
      _unsavedPickedPath = path;
    });
    if (previous != null) _deleteQuietly(previous);
  }

  void _removeReceipt() {
    final previous = _unsavedPickedPath;
    setState(() {
      _imagePath = null;
      _unsavedPickedPath = null;
    });
    if (previous != null) _deleteQuietly(previous);
  }


  Future<void> _openReceiptSheet() async {
    final path = _imagePath;
    if (path == null) return;
    final theme = Theme.of(context);
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image(
                  image: StoredImages.provider(path),
                  height: 220,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    height: 220,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: AppIcon(
                      Icons.broken_image_outlined,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _showAttachReceiptSheet();
                      },
                      icon: const AppIcon(Icons.swap_horiz_rounded),
                      label: const Tr('Replace'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.expense,
                      ),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _removeReceipt();
                      },
                      icon: const AppIcon(Icons.delete_outline),
                      label: const Tr('Remove'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Split expenses ────────────────────────────────────────────────────────

  Future<void> _pickSplitCategory(int index) async {
    final selected = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CategoryPickerSheet(
        kind: CategoryKind.expense,
        envelopeAccountId: _envelopeAccountId,
        modeId: _pickerModeId,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _splitRows[index].categoryId = selected);
  }

  Widget _splitToggleTile() {
    final theme = Theme.of(context);
    return AppCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: AppSwitchListTile(
        value: _isSplit,
        onChanged: (v) => setState(() {
          _isSplit = v;
          // Splitting by category and by account at once is a 2-D matrix
          // this screen doesn't offer — turning one on turns the other off.
          if (v) {
            _isHybridPayment = false;
            _hasChange = false;
          }
          while (v && _splitRows.length < 2) {
            _splitRows.add(_SplitEntry());
          }
        }),
        secondary: AppIcon(
          Icons.call_split_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: const Tr('Split into categories'),
        subtitle: _isSplit
            ? null
            : const Tr('One payment, more than one category'),
      ),
    );
  }

  // ── Hybrid payment ───────────────────────────────────────────────────────

  Future<void> _pickHybridLegAccount(int index) async {
    final excludeIds = {
      for (var i = 0; i < _hybridLegs.length; i++)
        if (i != index && _hybridLegs[i].accountId != null)
          _hybridLegs[i].accountId!,
    };
    final selected = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AccountPickerSheet(
        title: tr('Account'),
        excludeGoals: true,
        moneyInOut: true,
        excludeIds: excludeIds,
        modeId: _pickerModeId,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _hybridLegs[index].accountId = selected);
  }

  /// Merges what used to be two separate toggle cards
  /// (`_splitToggleTile` / the old hybrid-payment switch) into one: tap
  /// either label and the knob between them slides to that side and turns
  /// it on; tap the active side again and it slides back to the neutral
  /// middle — the shared default, and the only state where neither
  /// [_isSplit] nor [_isHybridPayment] is set. Creation-only, same as
  /// [_isHybridPayment] itself — [_splitToggleTile] above is what an
  /// existing transaction being edited gets instead, since there's nothing
  /// to merge it with there.
  Widget _splitModeToggleTile() {
    final theme = Theme.of(context);
    final mode = _isSplit
        ? _SplitMode.categories
        : (_isHybridPayment ? _SplitMode.accounts : null);

    return AppCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _splitModeLabel(
                    theme,
                    tr('Split into categories'),
                    active: mode == _SplitMode.categories,
                    onTap: () => _setSplitMode(_SplitMode.categories),
                  ),
                ),
                _SplitModeKnob(mode: mode),
                Expanded(
                  child: _splitModeLabel(
                    theme,
                    tr('Split into accounts'),
                    active: mode == _SplitMode.accounts,
                    onTap: () => _setSplitMode(_SplitMode.accounts),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              switch (mode) {
                null => tr('One payment — tap either side to split it up'),
                _SplitMode.categories => tr('One payment, more than one category'),
                _SplitMode.accounts =>
                  tr('One purchase, paid from more than one account'),
              },
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _splitModeLabel(
    ThemeData theme,
    String text, {
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// Tapping the side that's already active turns it off (back to the
  /// neutral middle); tapping the other side — or the middle — turns that
  /// side on instead. The on-path for each side keeps exactly the side
  /// effects its old standalone switch had (see the removed
  /// `_hybridToggleTile` / [_splitToggleTile]'s own `onChanged`): split
  /// turns off hybrid and change; hybrid turns off split, change and
  /// foreign currency.
  void _setSplitMode(_SplitMode side) {
    setState(() {
      final currentlyOn = side == _SplitMode.categories
          ? _isSplit
          : _isHybridPayment;
      if (currentlyOn) {
        if (side == _SplitMode.categories) {
          _isSplit = false;
        } else {
          _isHybridPayment = false;
        }
        return;
      }
      if (side == _SplitMode.categories) {
        _isSplit = true;
        _isHybridPayment = false;
        _hasChange = false;
        while (_splitRows.length < 2) {
          _splitRows.add(_SplitEntry());
        }
      } else {
        _isHybridPayment = true;
        _isSplit = false;
        _hasChange = false;
        _hasForeignCurrency = false;
        while (_hybridLegs.length < 2) {
          _hybridLegs.add(_PaymentLegEntry());
        }
      }
    });
  }

  Widget _hybridEditorCard(Map<int, AccountRow> accountMap) {
    final theme = Theme.of(context);
    final sum = _hybridLegs.fold(const Money.zero(), (s, r) => s + r.amount);
    final remaining = _amount - sum;

    return AppCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < _hybridLegs.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _hybridLegTile(i, accountMap),
            ],
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _hybridLegs.add(_PaymentLegEntry())),
                icon: const AppIcon(Icons.add_rounded, size: 18),
                label: const Tr('Add account'),
              ),
            ),
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Tr(
                  'Remaining',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                MoneyText(
                  remaining,
                  signed: true,
                  color: remaining.isZero
                      ? AppColors.income
                      : AppColors.expense,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _hybridLegTile(int index, Map<int, AccountRow> accountMap) {
    final theme = Theme.of(context);
    final row = _hybridLegs[index];
    final account = accountMap[row.accountId];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _pickHybridLegAccount(index),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outline),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(
                  AppIcons.resolve(account?.iconKey ?? 'cash'),
                  size: 18,
                  color: account != null
                      ? Color(account.colorValue)
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 84),
                  child: Text(
                    account?.name ?? tr('Account'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AmountKeypadDisplayBox(
            text: row.amountCtrl.text,
            active: identical(_activeAmountCtrl, row.amountCtrl),
            onTap: () => _activateAmountCtrl(row.amountCtrl),
            hintText: '0.00',
            isDense: true,
          ),
        ),
        IconButton(
          icon: const AppIcon(Icons.close_rounded, size: 18),
          tooltip: tr('Remove'),
          onPressed: _hybridLegs.length <= 1
              ? null
              : () => setState(() {
                  final removed = _hybridLegs.removeAt(index);
                  if (identical(_activeAmountCtrl, removed.amountCtrl)) {
                    _activeAmountCtrl = _mainAmountCtrl;
                  }
                  removed.dispose();
                }),
        ),
      ],
    );
  }

  // ── Change ────────────────────────────────────────────────────────────────

  Future<void> _pickChangeAccount() async {
    final selected = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AccountPickerSheet(
        title: tr('Change to account'),
        excludeId: _accountId,
        onlyTypes: const {AccountType.cash},
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _changeAccountId = selected);
  }

  Widget _changeToggleTile() {
    final theme = Theme.of(context);
    return AppCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: AppSwitchListTile(
        value: _hasChange,
        onChanged: (v) => setState(() {
          _hasChange = v;
          if (v) {
            _isSplit = false;
            _isHybridPayment = false;
            _hasForeignCurrency = false;
          }
        }),
        secondary: AppIcon(
          Icons.currency_exchange_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: const Tr('Change went elsewhere'),
        subtitle: _hasChange
            ? null
            : const Tr('Part of the change lands in another account'),
      ),
    );
  }

  // ── Foreign currency ─────────────────────────────────────────────────────

  Future<void> _pickForeignCurrency() async {
    final picked = await CurrencyPickerSheet.pick(
      context,
      initialCode: _foreignCurrencyCode ?? MoneyFormat.currency.code,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _foreignCurrencyCode = picked.code;
      // Only re-convert an amount the rate wrote — a typed one stays put.
      if (_amountFromRate || !_amount.isPositive) _fillAmountFromForeign();
    });
  }

  Widget _foreignToggleTile() {
    final theme = Theme.of(context);
    return AppCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: AppSwitchListTile(
        value: _hasForeignCurrency,
        onChanged: (v) => setState(() {
          _hasForeignCurrency = v;
          if (v) {
            _isHybridPayment = false;
            _hasChange = false;
          }
        }),
        secondary: AppIcon(
          Icons.public_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: const Tr('Foreign currency'),
        subtitle: _hasForeignCurrency
            ? null
            : const Tr('Record what this cost in another currency'),
      ),
    );
  }

  Widget _foreignCurrencyEditorCard() {
    final theme = Theme.of(context);
    final currency = currencyForCode(_foreignCurrencyCode);
    final foreignAmount = _foreignAmount;
    // Watched so the rates are loaded (and current) by the time a key is
    // typed — [_foreignRate] only reads them.
    ref.watch(currencyRatesProvider);
    final parentCode = MoneyFormat.currency.code;
    final isOtherCurrency =
        _foreignCurrencyCode != null && _foreignCurrencyCode != parentCode;
    final savedRate = isOtherCurrency ? _foreignRate : null;

    // What the two amounts as entered say the rate is.
    final implied = foreignAmount.isPositive && _amount.isPositive
        ? '1 ${currency.code} ≈ '
              '${MoneyFormat.symbol(Money.fromRupees(_amount.rupees / foreignAmount.rupees))}'
        : null;
    final String? rateLine;
    if (savedRate != null) {
      final overridden =
          implied != null &&
          _amount != convertUsingRate(foreignAmount, savedRate);
      rateLine =
          tr('At your saved rate, 1 {0} = '
          '{1} {2}.'
          '{3}', [currency.code, (savedRate / currencyRateScale).toStringAsFixed(4), parentCode, overridden ? tr(' The amount you entered works out to {0}.', [implied]) : '']);
    } else if (isOtherCurrency) {
      rateLine =
          tr('{0}. '
          'Save a {1} rate in Settings › Currencies and the '
          'amount fills in for you.', [implied ?? tr('No {0} rate saved yet', [currency.code]), currency.code]);
    } else {
      rateLine = implied;
    }

    return AppCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _pickForeignCurrency,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: theme.colorScheme.outline),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currency.symbol,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(currency.code, style: theme.textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AmountKeypadDisplayBox(
                    text: _foreignAmountCtrl.text,
                    active: identical(_activeAmountCtrl, _foreignAmountCtrl),
                    onTap: () => _activateAmountCtrl(_foreignAmountCtrl),
                    hintText: '0.00',
                    isDense: true,
                    showPrefix: false,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const AppIcon(Icons.close_rounded, size: 20),
                  tooltip: tr('Remove foreign currency'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => setState(() {
                    _hasForeignCurrency = false;
                    _foreignAmountCtrl.text = '';
                    if (identical(_activeAmountCtrl, _foreignAmountCtrl)) {
                      _activeAmountCtrl = _mainAmountCtrl;
                    }
                  }),
                ),
              ],
            ),
            if (rateLine != null) ...[
              const SizedBox(height: 8),
              Text(
                rateLine,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _changeEditorCard(Map<int, AccountRow> accountMap) {
    final theme = Theme.of(context);
    final account = accountMap[_changeAccountId];

    return AppCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _pickChangeAccount,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outline),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon(
                      AppIcons.resolve(account?.iconKey ?? 'cash'),
                      size: 18,
                      color: account != null
                          ? Color(account.colorValue)
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 100),
                      child: Text(
                        account?.name ?? tr('Account'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AmountKeypadDisplayBox(
                text: _changeAmountCtrl.text,
                active: identical(_activeAmountCtrl, _changeAmountCtrl),
                onTap: () => _activateAmountCtrl(_changeAmountCtrl),
                hintText: '0.00',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Editing an expense saved with "Change went elsewhere": the change is its
  /// own transfer row (see `AppDatabase.addExpenseWithChange`), so instead of
  /// the creation-only toggle, point at that leg — tap to edit it there.
  /// Without this the change just seemed to vanish (GitHub #179). Null for
  /// anything else, a loan payment's principal leg included.
  Widget? _linkedChangeCard(Map<int, AccountRow> accountMap) {
    if (!_isEditing || _type != TxType.expense) return null;
    final legs =
        ref
            .watch(paymentGroupLegsProvider(widget.transactionId!))
            .valueOrNull ??
        const <TransactionRow>[];
    TransactionRow? change;
    for (final l in legs) {
      if (l.id != widget.transactionId &&
          l.type == TxType.transfer &&
          accountMap[l.toAccountId]?.type != AccountType.loan) {
        change = l;
        break;
      }
    }
    if (change == null) return null;
    final theme = Theme.of(context);
    final leg = change;
    return AppCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: () => context.push('/add?id=${leg.id}'),
        leading: AppIcon(
          Icons.currency_exchange_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(
          tr('Change {0} to '
          '{1}', [MoneyFormat.symbol(leg.amount), accountMap[leg.toAccountId]?.name ?? '—']),
        ),
        subtitle: const Tr('Saved as its own transfer · tap to edit'),
        trailing: AppIcon(
          Icons.chevron_right_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _splitEditorCard(Map<int, CategoryRow> categoryMap) {
    final theme = Theme.of(context);
    final sum = _splitRows.fold(const Money.zero(), (s, r) => s + r.amount);
    final remaining = _amount - sum;

    return AppCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < _splitRows.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _splitRowTile(i, categoryMap),
            ],
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _splitRows.add(_SplitEntry())),
                icon: const AppIcon(Icons.add_rounded, size: 18),
                label: const Tr('Add category'),
              ),
            ),
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Tr(
                  'Remaining',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                MoneyText(
                  remaining,
                  signed: true,
                  color: remaining.isZero
                      ? AppColors.income
                      : AppColors.expense,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _splitRowTile(int index, Map<int, CategoryRow> categoryMap) {
    final theme = Theme.of(context);
    final row = _splitRows[index];
    final cat = categoryMap[row.categoryId];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _pickSplitCategory(index),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outline),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KeyIcon(
                  cat?.iconKey ?? 'other',
                  size: 18,
                  color: cat != null
                      ? Color(cat.colorValue)
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 84),
                  child: Text(
                    cat?.name ?? tr('Category'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AmountKeypadDisplayBox(
            text: row.amountCtrl.text,
            active: identical(_activeAmountCtrl, row.amountCtrl),
            onTap: () => _activateAmountCtrl(row.amountCtrl),
            hintText: '0.00',
            isDense: true,
          ),
        ),
        IconButton(
          icon: const AppIcon(Icons.close_rounded, size: 18),
          tooltip: tr('Remove'),
          onPressed: _splitRows.length <= 1
              ? null
              : () => setState(() {
                  final removed = _splitRows.removeAt(index);
                  if (identical(_activeAmountCtrl, removed.amountCtrl)) {
                    _activeAmountCtrl = _mainAmountCtrl;
                  }
                  removed.dispose();
                }),
        ),
      ],
    );
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final amount = _amount;

    // Zero is a legitimate income/expense (GitHub #87) — a free item, a
    // discount that fully covers the price, a promo month that costs
    // nothing. A transfer of ₹0 has no real meaning, so that stays
    // strictly positive.
    final amountValid =
        (_type == TxType.income || _type == TxType.expense) && !_isHybrid
        ? !amount.isNegative
        : amount.isPositive;
    if (!amountValid) {
      messenger.showSnackBar(
        const SnackBar(content: Tr('Enter a valid amount')),
      );
      return;
    }
    if (!await _withinModeLimits(amount) || !mounted) return;
    if (_isHybrid) {
      if (_hybridLegs.any((r) => r.accountId == null)) {
        messenger.showSnackBar(
          const SnackBar(content: Tr('Choose an account for every leg')),
        );
        return;
      }
      if (_hybridLegs.any((r) => !r.amount.isPositive)) {
        messenger.showSnackBar(
          const SnackBar(
            content: Tr('Every leg needs an amount greater than zero'),
          ),
        );
        return;
      }
      final sum = _hybridLegs.fold(const Money.zero(), (s, r) => s + r.amount);
      if (sum != amount) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              sum < amount
                  ? tr('Accounts are short by {0}', [MoneyFormat.symbol(amount - sum)])
                  : tr('Accounts are over by {0}', [MoneyFormat.symbol(sum - amount)]),
            ),
          ),
        );
        return;
      }
      // No category requirement here — an uncategorised split payment is a
      // legitimate choice, same as an ordinary uncategorised expense below.
      try {
        final db = ref.read(dbProvider);
        final note = _noteController.text.trim();
        final payeeText = _payeeController.text.trim();
        final ids = await db.addHybridPaymentTransaction(
          legs: [
            for (final leg in _hybridLegs)
              (accountId: leg.accountId!, amount: leg.amount),
          ],
          categoryId: _categoryId,
          date: _date,
          note: note.isEmpty ? null : note,
          payee: payeeText.isEmpty ? null : payeeText,
          personId: payeeText.isEmpty ? null : _payeePersonId,
          imagePath: _imagePath,
          customIcon: _customIcon,
          isNct: _isNct,
          modeId: _pickerModeId,
        );
        // The receipt (if any) is now referenced by a saved row — no longer
        // an orphan `dispose()` needs to clean up. Tags apply to the anchor
        // leg only, same reasoning as the receipt.
        _unsavedPickedPath = null;
        await db.setTransactionTags(ids.first, _tagIds);
        if (widget.plannedCostId != null) {
          await db.setPlannedCostPaid(widget.plannedCostId!, ids.first);
        }
      } on ArgumentError catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              e.message?.toString() ?? tr('Could not save transaction'),
            ),
          ),
        );
        return;
      }
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Tr('Saved')));
      return;
    }
    if (_accountId == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _type == TxType.transfer
                ? tr('Choose the account to transfer from')
                : tr('Choose an account'),
          ),
        ),
      );
      return;
    }
    if (_isChange) {
      if (_changeAccountId == null) {
        messenger.showSnackBar(
          const SnackBar(content: Tr('Choose where the change goes')),
        );
        return;
      }
      if (!_changeAmount.isPositive) {
        messenger.showSnackBar(
          const SnackBar(content: Tr('Enter how much change goes there')),
        );
        return;
      }
      // No category requirement here either — see the same note on the
      // hybrid-payment path above.
      try {
        final db = ref.read(dbProvider);
        final note = _noteController.text.trim();
        final payeeText = _payeeController.text.trim();
        final ids = await db.addExpenseWithChange(
          amount: amount,
          accountId: _accountId!,
          categoryId: _categoryId,
          changeAccountId: _changeAccountId!,
          changeAmount: _changeAmount,
          date: _date,
          note: note.isEmpty ? null : note,
          payee: payeeText.isEmpty ? null : payeeText,
          personId: payeeText.isEmpty ? null : _payeePersonId,
          imagePath: _imagePath,
          customIcon: _customIcon,
          modeId: _pickerModeId,
        );
        _unsavedPickedPath = null;
        await db.setTransactionTags(ids.first, _tagIds);
      } on ArgumentError catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              e.message?.toString() ?? tr('Could not save transaction'),
            ),
          ),
        );
        return;
      }
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Tr('Saved')));
      return;
    }
    int? envelopeShortfallCategoryId;
    var envelopeShortfall = const Money.zero();
    if (_type == TxType.transfer) {
      if (_toAccountId == null) {
        messenger.showSnackBar(
          const SnackBar(content: Tr('Choose the account to transfer to')),
        );
        return;
      }
      if (_toAccountId == _accountId) {
        messenger.showSnackBar(
          const SnackBar(
            content: Tr('Transfer must be between two different accounts'),
          ),
        );
        return;
      }
      // Only a brand-new transfer — editing one that already resolved its
      // own shortfall would otherwise record a second, duplicate allocation
      // on top of the first.
      if (!_isEditing) {
        envelopeShortfall = envelopeOutflowShortfall(
          ref,
          accountId: _accountId!,
          amount: amount,
        );
        if (envelopeShortfall.isPositive) {
          final picked = await pickEnvelopeShortfallCategory(
            context: context,
            accountId: _accountId!,
            shortfall: envelopeShortfall,
          );
          if (picked == null || !mounted) return;
          envelopeShortfallCategoryId = picked;
        }
      }
    } else if (_isSplitting) {
      if (_splitRows.any((r) => r.categoryId == null)) {
        messenger.showSnackBar(
          const SnackBar(content: Tr('Choose a category for every split')),
        );
        return;
      }
      if (_splitRows.any((r) => !r.amount.isPositive)) {
        messenger.showSnackBar(
          const SnackBar(
            content: Tr('Every split needs an amount greater than zero'),
          ),
        );
        return;
      }
      final sum = _splitRows.fold(const Money.zero(), (s, r) => s + r.amount);
      if (sum != amount) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              sum < amount
                  ? tr('Splits are short by {0}', [MoneyFormat.symbol(amount - sum)])
                  : tr('Splits are over by {0}', [MoneyFormat.symbol(sum - amount)]),
            ),
          ),
        );
        return;
      }
    }
    // No `else if (_categoryId == null)` branch here — an ordinary income or
    // expense with no category picked is a legitimate, intentional choice:
    // it just posts uncategorised, same as any transaction whose category
    // was later deleted already renders (see `_categoryValue` on the
    // transaction detail screen).
    // A mode's currency opens the foreign amount ready (see `_seedMode`);
    // left empty, this one simply has none.
    final useForeign =
        _isForeignCurrency && !(_foreignFromMode && !_foreignAmount.isPositive);
    if (useForeign &&
        (_foreignCurrencyCode == null || !_foreignAmount.isPositive)) {
      messenger.showSnackBar(
        const SnackBar(content: Tr('Choose a currency and enter its amount')),
      );
      return;
    }

    final note = _noteController.text.trim();
    final payeeText = _payeeController.text.trim();
    final payee =
        (_type == TxType.expense || _type == TxType.income) &&
            payeeText.isNotEmpty
        ? payeeText
        : null;
    // A split expense has no single category of its own — see
    // AppDatabase.setTransactionSplits.
    final categoryId = (_type == TxType.transfer || _isSplitting)
        ? null
        : _categoryId;
    final foreignCurrencyCode = useForeign ? _foreignCurrencyCode : null;
    final foreignAmount = useForeign ? _foreignAmount : null;
    try {
      final db = ref.read(dbProvider);
      int id;
      if (_isEditing) {
        id = widget.transactionId!;
        await db.updateTransaction(
          id: id,
          type: _type,
          amount: amount,
          accountId: _accountId!,
          toAccountId: _type == TxType.transfer ? _toAccountId : null,
          categoryId: categoryId,
          date: _date,
          note: note.isEmpty ? null : note,
          payee: payee,
          personId: payee == null ? null : _payeePersonId,
          imagePath: _imagePath,
          foreignCurrencyCode: foreignCurrencyCode,
          foreignAmount: foreignAmount,
          customIcon: _customIcon,
          isNct: _isNct,
        );
        if (_mode != null) {
          await db.setTransactionMode(id, _pickerModeId);
        }
      } else if (_splitsWithPeople) {
        // Split with the mode's people: a group expense in the mode's group
        // — you paid, equal shares — so each share becomes a trip due.
        final expenseId = await db.addGroupExpense(
          groupId: _mode!.groupId!,
          amount: amount,
          splitMethod: GroupSplitMethod.equal,
          date: _date,
          note: note.isEmpty ? (payee ?? tr('Split')) : note,
          accountId: _accountId!,
          categoryId: categoryId,
          participantIds: {null, ..._splitWith},
        );
        final mine = await db.myGroupShareTransactionId(expenseId);
        if (mine == null) throw ArgumentError(tr('Could not split this one.'));
        id = mine;
      } else {
        id = await db.addTransaction(
          type: _type,
          amount: amount,
          accountId: _accountId!,
          toAccountId: _type == TxType.transfer ? _toAccountId : null,
          categoryId: categoryId,
          date: _date,
          note: note.isEmpty ? null : note,
          payee: payee,
          personId: payee == null ? null : _payeePersonId,
          imagePath: _imagePath,
          foreignCurrencyCode: foreignCurrencyCode,
          foreignAmount: foreignAmount,
          customIcon: _customIcon,
          isNct: _isNct,
          modeId: _pickerModeId,
        );
      }
      // The receipt (if any) is now referenced by a saved row — no longer an
      // orphan `dispose()` needs to clean up.
      _unsavedPickedPath = null;
      await db.setTransactionTags(id, _tagIds);
      if (widget.plannedCostId != null) {
        await db.setPlannedCostPaid(widget.plannedCostId!, id);
      }
      await db.setTransactionSplits(
        id,
        _isSplitting
            ? [
                for (final r in _splitRows)
                  (categoryId: r.categoryId!, amount: r.amount),
              ]
            : const [],
      );
      // Written only after the transfer itself is safely saved — a failed
      // transfer must never leave a stray allocation behind with nothing to
      // account for.
      if (envelopeShortfallCategoryId != null) {
        await db.addAllocation(
          accountId: _accountId!,
          categoryId: envelopeShortfallCategoryId,
          amount: -envelopeShortfall,
          date: _date,
          note: tr('Drawn for a transfer out of this account'),
        );
      }
    } on ArgumentError catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(e.message?.toString() ?? tr('Could not save transaction')),
        ),
      );
      return;
    }

    navigator.pop();
    messenger.showSnackBar(
      SnackBar(content: Text(_isEditing ? tr('Updated') : tr('Saved'))),
    );
  }

  // ── Delete ──────────────────────────────────────────────────────────────

  Future<void> _confirmDelete() async {
    final theme = Theme.of(context);
    // Capture before the first await — never touch `context` across the gap.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Tr('Delete this transaction?'),
        content: const Tr('The amount will be added back to your balance.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Tr('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Tr('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref.read(dbProvider).deleteTransaction(widget.transactionId!);
    } on ArgumentError catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message?.toString() ?? tr('Could not delete'))),
      );
      return;
    }
    if (!mounted) return;

    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Tr('Transaction deleted')),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accountMap = ref.watch(accountMapProvider);
    final categoryMap = ref.watch(categoryMapProvider);
    // Kept warm from the moment this screen opens, not read for the first
    // time inside `_save`: `envelopeOutflowShortfall` needs a real value
    // already in hand the instant Save is tapped, and a provider nothing
    // else here watches only starts loading on its first read.
    ref.watch(allAllocationsProvider);
    final amount = _amount;
    // The amount always debits/credits _accountId — the source account for
    // every type, transfer included — so that's whose currency the hero
    // figure and its keypad are in. Null means the parent currency, which
    // is also what every existing screen already renders (no account
    // selected yet defaults to the same thing it always has).
    final txCurrency = _currencyForAccount(_accountId, accountMap);
    // A mutually-exclusive toggle (split/hybrid/change/foreign) or a type
    // switch can hide the card `_activeAmountCtrl` was pointing into without
    // going through a single call site that could reset it — re-check on
    // every build instead, so the shared keypad never silently keeps editing
    // a field the user can no longer see.
    if (!_isSplitting &&
        _splitRows.any((r) => identical(_activeAmountCtrl, r.amountCtrl))) {
      _activeAmountCtrl = _mainAmountCtrl;
    }
    if (!_isHybrid &&
        _hybridLegs.any((r) => identical(_activeAmountCtrl, r.amountCtrl))) {
      _activeAmountCtrl = _mainAmountCtrl;
    }
    if (!_isChange && identical(_activeAmountCtrl, _changeAmountCtrl)) {
      _activeAmountCtrl = _mainAmountCtrl;
    }
    if (!_isForeignCurrency &&
        identical(_activeAmountCtrl, _foreignAmountCtrl)) {
      _activeAmountCtrl = _mainAmountCtrl;
    }

    _desktop = DesktopLayout.of(context);

    // An NCT transaction's details are on screen in full here — no frosting
    // a form — so captures stay blocked while the switch is on.
    return SecureWhile(
      active: _isNct,
      holdBack: false,
      child: PopScope(
        canPop: _step == _AddScreenStep.operation || _isEditing,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_step == _AddScreenStep.keypad && !_isEditing) {
            setState(() => _step = _AddScreenStep.operation);
          }
        },
        child: Scaffold(
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  child: _step == _AddScreenStep.operation
                      ? _buildOperationStep(theme, accountMap, categoryMap)
                      : _buildKeypadStep(
                          theme,
                          accountMap,
                          categoryMap,
                          txCurrency,
                          amount,
                        ),
                ),
        ),
      ),
    );
  }

  Widget _buildOperationStep(
    ThemeData theme,
    Map<int, AccountRow> accountMap,
    Map<int, CategoryRow> categoryMap,
  ) {
    return Column(
      children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.center,
                child: Text(
                  tr('Add an operation'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: const AppIcon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              _operationTabButton(theme, tr('Money in'), _OperationTab.moneyIn),
              _operationTabButton(theme, tr('Money out'), _OperationTab.moneyOut),
              _operationTabButton(theme, tr('Transfer'), _OperationTab.transfer),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _buildOperationGrid(theme, accountMap, categoryMap),
        ),
      ],
    );
  }

  Widget _operationTabButton(
    ThemeData theme,
    String label,
    _OperationTab tab,
  ) {
    final isSelected = _operationTab == tab;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _operationTab = tab),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected
                    ? (tab == _OperationTab.moneyOut
                        ? colorForTxType(TxType.expense)
                        : (tab == _OperationTab.moneyIn
                            ? colorForTxType(TxType.income)
                            : colorForTxType(TxType.transfer)))
                    : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              color: isSelected
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOperationGrid(
    ThemeData theme,
    Map<int, AccountRow> accountMap,
    Map<int, CategoryRow> categoryMap,
  ) {
    if (_operationTab == _OperationTab.transfer) {
      final accounts = ref.watch(accountsProvider).valueOrNull ?? [];
      if (accounts.isEmpty) {
        return Center(
          child: Text(
            tr('No accounts yet'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      }
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16).plusNavBar(context),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 2.1,
        ),
        itemCount: accounts.length,
        itemBuilder: (context, index) {
          final acc = accounts[index];
          final color = Color(acc.colorValue);
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              setState(() {
                _type = TxType.transfer;
                _accountId = acc.id;
                _step = _AddScreenStep.keypad;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: AppIcon(
                        AppIcons.resolve(acc.iconKey),
                        color: color,
                        size: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          acc.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Builder(
                          builder: (context) {
                            final balance = acc.linkedAccountId != null
                                ? (accountMap[acc.linkedAccountId]?.currentBalance ??
                                    const Money.zero())
                                : acc.currentBalance;
                            return Text(
                              MoneyFormat.symbol(balance),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: balance.isPositive
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                                fontWeight: balance.isPositive
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    final isExpense = _operationTab == _OperationTab.moneyOut;
    final kind = isExpense ? CategoryKind.expense : CategoryKind.income;
    final topCategories = categoryMap.values
        .where((c) => c.kind == kind && c.parentId == null && !c.isArchived)
        .toList();

    final spendMap = isExpense
        ? (ref.watch(spendByCategoryProvider).valueOrNull ?? const {})
        : const <int, Money>{};

    final allTxs = !isExpense
        ? (ref.watch(allTransactionsProvider).valueOrNull ?? const [])
        : const <TransactionRow>[];

    final month = ref.watch(selectedMonthProvider);
    final startDay = ref.watch(budgetStartDayProvider);
    final period = budgetPeriodFor(month, startDay);

    final incomeMap = <int, Money>{};
    if (!isExpense) {
      for (final t in allTxs) {
        if (t.type == TxType.income &&
            t.categoryId != null &&
            !t.date.isBefore(period.start) &&
            !t.date.isAfter(period.end)) {
          incomeMap[t.categoryId!] =
              (incomeMap[t.categoryId!] ?? const Money.zero()) + t.amount;
        }
      }
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16).plusNavBar(context),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 2.1,
      ),
      itemCount: topCategories.length,
      itemBuilder: (context, index) {
        final cat = topCategories[index];
        final color = Color(cat.colorValue);

        Money total;
        if (isExpense) {
          total = spendMap[cat.id] ?? const Money.zero();
          for (final child in categoryMap.values) {
            if (child.parentId == cat.id) {
              total = total + (spendMap[child.id] ?? const Money.zero());
            }
          }
        } else {
          total = incomeMap[cat.id] ?? const Money.zero();
          for (final child in categoryMap.values) {
            if (child.parentId == cat.id) {
              total = total + (incomeMap[child.id] ?? const Money.zero());
            }
          }
        }

        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            setState(() {
              _type = isExpense ? TxType.expense : TxType.income;
              _categoryId = cat.id;
              _ensureDefaultAccount();
              _step = _AddScreenStep.keypad;
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: AppIcon(
                      AppIcons.resolve(cat.iconKey),
                      color: color,
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        cat.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        MoneyFormat.symbol(total),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: total.isPositive
                              ? (color != Colors.transparent
                                  ? color
                                  : theme.colorScheme.primary)
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: total.isPositive
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildKeypadStep(
    ThemeData theme,
    Map<int, AccountRow> accountMap,
    Map<int, CategoryRow> categoryMap,
    Currency? txCurrency,
    Money amount,
  ) {
    final activeCards = <Widget>[];
    if (_isSplitting) {
      activeCards.add(_splitEditorCard(categoryMap));
      activeCards.add(const SizedBox(height: 12));
    }
    if (_isHybrid) {
      activeCards.add(_hybridEditorCard(accountMap));
      activeCards.add(const SizedBox(height: 12));
    }
    if (_isChange) {
      activeCards.add(_changeEditorCard(accountMap));
      activeCards.add(const SizedBox(height: 12));
    }
    if (_hasForeignCurrency) {
      activeCards.add(_foreignCurrencyEditorCard());
      activeCards.add(const SizedBox(height: 12));
    }
    if (_isEditing) {
      final linkedChange = _linkedChangeCard(accountMap);
      if (linkedChange != null) {
        activeCards.add(linkedChange);
        activeCards.add(const SizedBox(height: 12));
      }
    }
    if (_type == TxType.transfer) {
      final preview = _crossCurrencyTransferPreview(accountMap);
      if (preview != null) {
        activeCards.add(preview);
        activeCards.add(const SizedBox(height: 8));
      }
      final warning = _minimumBalanceWarning(accountMap);
      if (warning != null) {
        activeCards.add(warning);
        activeCards.add(const SizedBox(height: 8));
      }
    }

    final noteText = _noteController.text.trim();
    final payeeText = _payeeController.text.trim();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: IconButton(
                      icon: const AppIcon(Icons.close_rounded, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: tr('Close'),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Top date bar: < Today, November 18 >
          _dateBar(theme),
          // Side-by-side cards: Account & Category
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: _sideBySideCards(theme, accountMap, categoryMap),
          ),
          // Subcategories pills
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _subcategoriesRow(theme, categoryMap),
          ),
          const SizedBox(height: 8),
          // Centered Hero Amount
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: GestureDetector(
              onTap: () => _activateAmountCtrl(_mainAmountCtrl),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  key: const Key('amountDisplay'),
                  _formatAmountDisplay(amount, txCurrency),
                  style: theme.textTheme.displayMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorForTxType(_type),
                    fontFeatures: kTabularFigures,
                  ),
                ),
              ),
            ),
          ),
          if (payeeText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 1),
              child: Text(
                payeeText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (noteText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 1),
              child: Text(
                noteText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          _selectedTagsChips(),
          const Spacer(),
          if (activeCards.isNotEmpty)
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: activeCards,
                ),
              ),
            ),
          // Action toolbar: 📎 💬 🏷️
          _actionToolbar(theme),
          // Calculator Keypad
          if (!_textFieldFocused && !_desktop)
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(12, 4, 12, 8).plusNavBar(context),
              child: CalculatorKeypadGrid(
                onDigit: _onCalcDigit,
                onOperator: _onCalcOperator,
                onBackspace: _onCalcBackspace,
                onSubmit: _onCalcSubmit,
                onMore: () => _showMoreOptionsSheet(context),
                onCurrency: _onCalcCurrency,
              ),
            ),
        ],
      ),
    );
  }

  Widget _dateBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          IconButton(
            icon: const AppIcon(Icons.chevron_left_rounded),
            onPressed: () => setState(() {
              _date = _date.subtract(const Duration(days: 1));
            }),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _pickDate,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const AppIcon(Icons.calendar_today_rounded, size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _formatDateWithRelative(_date),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: const AppIcon(Icons.access_time_rounded, size: 18),
                      tooltip: tr('Change time'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _pickTime,
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const AppIcon(Icons.chevron_right_rounded),
            onPressed: () => setState(() {
              _date = _date.add(const Duration(days: 1));
            }),
          ),
        ],
      ),
    );
  }

  String _formatDateWithRelative(DateTime d) {
    final now = DateTime.now();
    final isToday =
        d.year == now.year && d.month == now.month && d.day == now.day;
    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday = d.year == yesterday.year &&
        d.month == yesterday.month &&
        d.day == yesterday.day;
    final tomorrow = now.add(const Duration(days: 1));
    final isTomorrow = d.year == tomorrow.year &&
        d.month == tomorrow.month &&
        d.day == tomorrow.day;

    final datePart = isToday
        ? 'Today, ${DateFormat('MMMM d').format(d)}'
        : isYesterday
        ? 'Yesterday, ${DateFormat('MMMM d').format(d)}'
        : isTomorrow
        ? 'Tomorrow, ${DateFormat('MMMM d').format(d)}'
        : DateFormat('d MMM yyyy').format(d);
    final timePart = DateFormat('h:mm a').format(d);
    return '$datePart, $timePart';
  }

  Widget _sideBySideCards(
    ThemeData theme,
    Map<int, AccountRow> accountMap,
    Map<int, CategoryRow> categoryMap,
  ) {
    final isTransfer = _type == TxType.transfer;
    final fromAccount = accountMap[_accountId];
    final toAccount = accountMap[_toAccountId];
    final category = categoryMap[_categoryId];
    final categoryColor = category != null
        ? Color(category.colorValue)
        : theme.colorScheme.primary;

    return Row(
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _pickAccount(isFrom: true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isTransfer ? tr('From account') : tr('Account'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      AppIcon(
                        AppIcons.resolve(fromAccount?.iconKey ?? 'credit_card'),
                        size: 20,
                        color: fromAccount != null
                            ? Color(fromAccount.colorValue)
                            : theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          fromAccount?.name ?? tr('Select account'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: isTransfer
                ? () => _pickAccount(isFrom: false)
                : (_isEditing
                    ? _pickCategory
                    : () => setState(() => _step = _AddScreenStep.operation)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isTransfer
                    ? theme.colorScheme.surfaceContainerLow
                    : categoryColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isTransfer
                      ? theme.colorScheme.outlineVariant.withValues(alpha: 0.5)
                      : categoryColor.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isTransfer ? tr('To account') : tr('Category'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isTransfer
                          ? theme.colorScheme.onSurfaceVariant
                          : categoryColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      AppIcon(
                        isTransfer
                            ? AppIcons.resolve(toAccount?.iconKey ?? 'credit_card')
                            : AppIcons.resolve(category?.iconKey ?? 'category'),
                        size: 20,
                        color: isTransfer
                            ? (toAccount != null
                                ? Color(toAccount.colorValue)
                                : theme.colorScheme.primary)
                            : categoryColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isTransfer
                              ? (toAccount?.name ?? tr('Select account'))
                              : (category?.name ?? tr('Select category')),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: isTransfer ? null : categoryColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _subcategoriesRow(
    ThemeData theme,
    Map<int, CategoryRow> categoryMap,
  ) {
    if (_type == TxType.transfer || _categoryId == null) {
      return const SizedBox.shrink();
    }
    final current = categoryMap[_categoryId];
    if (current == null) return const SizedBox.shrink();

    final int parentId = current.parentId ?? current.id;
    final parent = categoryMap[parentId] ?? current;
    final subcategories = categoryMap.values
        .where((c) => c.parentId == parentId && !c.isArchived)
        .toList();

    if (subcategories.isEmpty) return const SizedBox.shrink();

    final parentColor = Color(parent.colorValue);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: subcategories.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final sub = subcategories[index];
            final isSelected = _categoryId == sub.id;
            return ActionChip(
              label: Text(
                sub.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? parentColor : theme.colorScheme.onSurface,
                ),
              ),
              backgroundColor: isSelected
                  ? parentColor.withValues(alpha: 0.15)
                  : theme.colorScheme.surface,
              side: BorderSide(
                color: isSelected
                    ? parentColor
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                width: isSelected ? 1.5 : 1,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              onPressed: () {
                setState(() {
                  if (isSelected) {
                    _categoryId = parentId;
                  } else {
                    _categoryId = sub.id;
                  }
                });
              },
            );
          },
        ),
      ),
    );
  }

  Widget _actionToolbar(ThemeData theme) {
    final hasReceipt = _imagePath != null;
    final hasNoteOrPayee = _noteController.text.trim().isNotEmpty ||
        _payeeController.text.trim().isNotEmpty;
    final hasTags = _tagIds.isNotEmpty;

    return Container(
      height: 46,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _toolbarItem(
              theme: theme,
              icon: Icons.attach_file_rounded,
              active: hasReceipt,
              badge: hasReceipt ? '1' : null,
              tooltip: tr('Receipt'),
              onTap: _imagePath != null ? _openReceiptSheet : _showAttachReceiptSheet,
            ),
          ),
          Container(
            width: 1,
            height: 24,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
          Expanded(
            child: _toolbarItem(
              theme: theme,
              icon: Icons.chat_bubble_outline_rounded,
              active: hasNoteOrPayee,
              tooltip: tr('Note & Payee'),
              onTap: () => _showNotePayeeSheet(context),
            ),
          ),
          Container(
            width: 1,
            height: 24,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
          Expanded(
            child: _toolbarItem(
              theme: theme,
              icon: Icons.local_offer_outlined,
              active: hasTags,
              badge: hasTags ? '${_tagIds.length}' : null,
              tooltip: tr('Tags'),
              onTap: _pickTags,
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbarItem({
    required ThemeData theme,
    required IconData icon,
    required bool active,
    String? badge,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                icon,
                size: 20,
                color: active
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showNotePayeeSheet(BuildContext context) async {
    final theme = Theme.of(context);
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          left: 20,
          right: 20,
          top: 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('Note & Payee'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            _payeeCard(),
            const SizedBox(height: 12),
            _noteCard(),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(tr('Done')),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _showMoreOptionsSheet(BuildContext context) async {
    final theme = Theme.of(context);
    final accountMap = ref.read(accountMapProvider);

    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text(
              tr('More options'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            if (_mode != null) ...[
              _modeToggleTile(_mode!),
              const SizedBox(height: 12),
              if (_splitWithTile(_mode!) != null) ...[
                _splitWithTile(_mode!)!,
                const SizedBox(height: 12),
              ],
            ],
            if (_type == TxType.expense) ...[
              _isEditing ? _splitToggleTile() : _splitModeToggleTile(),
              const SizedBox(height: 12),
              if (!_isEditing &&
                  accountMap[_accountId]?.type == AccountType.cash &&
                  accountMap.values
                          .where((a) => a.type == AccountType.cash)
                          .length >=
                      2) ...[
                _changeToggleTile(),
                const SizedBox(height: 12),
              ],
            ],
            if (_currencyForAccount(_accountId, accountMap) == null) ...[
              _foreignToggleTile(),
              const SizedBox(height: 12),
            ],
            _nctToggleTile(),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _customIcon == null
                  ? const AppIcon(Icons.emoji_emotions_outlined)
                  : CustomIconBadge(value: _customIcon!, size: 26),
              title: Text(
                _customIcon == null
                    ? tr('Add custom icon or emoji')
                    : tr('Change icon or emoji'),
              ),
              trailing: _customIcon != null
                  ? IconButton(
                      icon: const AppIcon(Icons.close_rounded),
                      onPressed: () {
                        setState(() => _customIcon = null);
                        Navigator.of(ctx).pop();
                      },
                    )
                  : const AppIcon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(ctx).pop();
                if (_customIcon == null) {
                  _pickCustomIcon();
                } else {
                  _openCustomIconSheet();
                }
              },
            ),
            if (_isEditing) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const AppIcon(Icons.delete_outline, color: Colors.red),
                label: Text(
                  tr('Delete transaction'),
                  style: const TextStyle(color: Colors.red),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _confirmDelete();
                },
              ),
            ],
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// "Split with" the mode's people — a new expense in a mode that has
  /// some, and nothing else splitting it already.
  Widget? _splitWithTile(ModeRow mode) {
    if (!_inMode ||
        mode.groupId == null ||
        _type != TxType.expense ||
        _isEditing ||
        _isSplitting ||
        _isHybrid ||
        _isChange) {
      return null;
    }
    final people = ref.watch(modePeopleProvider(mode.id));
    if (people.isEmpty) return null;
    final theme = Theme.of(context);
    final share = _splitWith.isEmpty
        ? null
        : Money(_amount.paise ~/ (_splitWith.length + 1));
    return AppCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              share == null
                  ? tr('Split with')
                  : tr('Split with · {0} each, you paid', [MoneyFormat.symbol(share)]),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in people)
                  FilterChip(
                    avatar: PersonAvatar(
                      name: p.name,
                      photoPath: p.photoPath,
                      radius: 12,
                      glow: false,
                    ),
                    label: Text(p.name),
                    selected: _splitWith.contains(p.id),
                    onSelected: (v) => setState(() {
                      _splitWith = {..._splitWith};
                      v ? _splitWith.add(p.id) : _splitWith.remove(p.id);
                    }),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// "Part of 🧳 Goa trip" — on for a new transaction while a mode is ON;
  /// off keeps this one out of it.
  Widget _modeToggleTile(ModeRow mode) {
    return AppCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: AppSwitchListTile(
        value: _inMode,
        onChanged: (v) => setState(() => _inMode = v),
        secondary: _iconCircle(mode.iconKey, mode.colorValue, size: 32),
        title: Text(tr('Part of {0}', [mode.name])),
        subtitle: Text(
          _inMode ? tr('Counted in this mode') : tr('Kept out of this mode'),
        ),
      ),
    );
  }

  Widget _nctToggleTile() {
    final theme = Theme.of(context);
    return AppCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: AppSwitchListTile(
        value: _isNct,
        onChanged: (v) => setState(() => _isNct = v),
        secondary: AppIcon(
          _isNct ? Icons.visibility_off_rounded : Icons.visibility_off_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: const Tr('Hide from screenshots'),
        subtitle: Text(
          _isNct
              ? tr('NCT · hidden in lists until held, captures blocked when open')
              : tr('NCT · keep it out of screenshots and recordings'),
        ),
      ),
    );
  }

  Widget _noteCard() {
    final theme = Theme.of(context);
    return AppCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _noteController,
          focusNode: _noteFocus,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: tr('Note (optional)'),
            border: InputBorder.none,
            icon: AppIcon(
              Icons.notes_outlined,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// Expense or income only (GitHub #62 — a salary needs a payee too, same as
  /// a purchase). Tapping opens the payee sheet — people, past payees and
  /// contacts, sized above the keyboard — instead of an inline field whose
  /// suggestions ended up hidden behind it. Optional: blank is normal.
  Widget _payeeCard() {
    final theme = Theme.of(context);
    final name = _payeeController.text.trim();
    final person = _payeePersonId == null
        ? null
        : ref.watch(allPersonsByIdProvider)[_payeePersonId];
    return AppCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _pickPayee,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            children: [
              if (person != null)
                PersonAvatar(
                  name: person.name,
                  photoPath: person.photoPath,
                  radius: 14,
                )
              else
                AppIcon(
                  Icons.storefront_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              const SizedBox(width: 16),
              Expanded(
                child: name.isEmpty
                    ? Text(
                        _type == TxType.income
                            ? tr('Payee (optional) — who paid you?')
                            : tr('Payee (optional) — who did you pay?'),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            person?.name ?? name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge,
                          ),
                          if (person != null)
                            Tr(
                              'Person · not counted in owe/due',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
              ),
              if (name.isNotEmpty)
                IconButton(
                  icon: const AppIcon(Icons.close_rounded),
                  tooltip: tr('Clear payee'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    _payeeController.clear();
                    _payeePersonId = null;
                  }),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: AppIcon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickPayee() async {
    FocusScope.of(context).unfocus();
    final current = _payeeController.text.trim();
    final choice = await showPayeePickerSheet(
      context,
      isIncome: _type == TxType.income,
      selectedName: current.isEmpty ? null : current,
      selectedPersonId: _payeePersonId,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _payeeController.text = choice.name;
      _payeePersonId = choice.name.isEmpty ? null : choice.personId;
    });
    final notice = choice.notice;
    if (notice != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(notice)));
    }
  }


  /// Picked tags shown as chips right under the amount — visible at a glance
  /// without opening the picker sheet again, and without eating space in the
  /// scrollable field list below.
  Widget _selectedTagsChips() {
    final tagMap = ref.watch(tagMapProvider);
    final selected = [
      for (final id in _tagIds)
        if (tagMap[id] != null) tagMap[id]!,
    ]..sort((a, b) => a.name.compareTo(b.name));
    if (selected.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final tag in selected)
            InkWell(
              onTap: _pickTags,
              borderRadius: BorderRadius.circular(20),
              child: Chip(
                label: Text(tag.name),
                backgroundColor: Color(tag.colorValue).withValues(alpha: 0.15),
                labelStyle: TextStyle(color: Color(tag.colorValue)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: BorderSide.none,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickTags() async {
    final result = await showAppSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          TagPickerSheet(initiallySelected: _tagIds, modeId: _pickerModeId),
    );
    if (result == null || !mounted) return;
    setState(() => _tagIds = result);
  }
}

enum _ReceiptSource { camera, gallery }

enum _CustomIconSource { library, emoji }

enum _SplitMode { categories, accounts }

/// The knob in [_AddTransactionScreenState._splitModeToggleTile] — a small
/// pill track whose filled circle animates to the left, right, or neutral
/// middle as [mode] changes, so picking a side visibly "moves" the button
/// the way a physical slider would, without needing a raw drag gesture.
class _SplitModeKnob extends StatelessWidget {
  const _SplitModeKnob({required this.mode});

  final _SplitMode? mode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alignment = switch (mode) {
      _SplitMode.categories => Alignment.centerLeft,
      _SplitMode.accounts => Alignment.centerRight,
      null => Alignment.center,
    };
    final knobColor = mode == null
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.primary;
    final knobIcon = switch (mode) {
      _SplitMode.categories => Icons.call_split_rounded,
      _SplitMode.accounts => Icons.account_balance_wallet_outlined,
      null => Icons.remove_rounded,
    };

    return Container(
      width: 64,
      height: 30,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: alignment,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(color: knobColor, shape: BoxShape.circle),
          child: AppIcon(knobIcon, size: 14, color: theme.colorScheme.surface),
        ),
      ),
    );
  }
}

/// A round badge showing an account/category icon on its own stored colour.
Widget _iconCircle(String iconKey, int colorValue, {double size = 40}) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: Color(colorValue), shape: BoxShape.circle),
    child: KeyIcon(iconKey, color: Colors.white, size: size * 0.5),
  );
}

/// Bottom sheet: pick an account (or a debit-card instrument) to pay/receive
/// with. Debit cards are selectable but show the bank they draw from instead of
/// a balance.
class _AccountPickerSheet extends ConsumerWidget {
  const _AccountPickerSheet({
    required this.title,
    this.excludeId,
    this.excludeIds = const {},
    this.excludeGoals = false,
    this.moneyInOut = false,
    this.onlyTypes,
    this.modeId,
  });

  final String title;

  /// Offers only the accounts this mode allows (all, if it sets no limit).
  final int? modeId;
  final int? excludeId;

  /// Every other hybrid-payment leg's already-chosen account — see GitHub
  /// #43. Not a replacement for [excludeId]; both apply together.
  final Set<int> excludeIds;

  /// A goal is a savings store, not a spendable account — only a transfer
  /// may fund or draw it down. Set for expense/income pickers.
  final bool excludeGoals;

  /// A money in / out picker: [excludeGoals] still lets through the goals
  /// whose "Show in Money in / out" is on (GitHub #173).
  final bool moneyInOut;

  /// Restricts the list to these account types when set — e.g. change from
  /// a cash payment only ever lands in another cash-type account, never a
  /// card or bank one (see GitHub #55).
  final Set<AccountType>? onlyTypes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accountsAsync = ref.watch(accountsProvider);
    final accountMap = ref.watch(accountMapProvider);
    final allowed = modeId == null
        ? const <int>{}
        : ref.watch(modeConfigProvider(modeId!)).accountIds;
    final moneyInOutGoals = moneyInOut
        ? ref.watch(moneyInOutGoalIdsProvider)
        : const <int>{};

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(title, style: theme.textTheme.titleLarge),
            ),
            Flexible(
              child: accountsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    tr('Could not load accounts.\n{0}', [e]),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                data: (accounts) {
                  final list = accounts
                      .where((a) => a.id != excludeId)
                      .where((a) => !excludeIds.contains(a.id))
                      .where(
                        (a) =>
                            !excludeGoals ||
                            a.type != AccountType.goal ||
                            moneyInOutGoals.contains(a.id),
                      )
                      .where((a) => onlyTypes?.contains(a.type) ?? true)
                      .where((a) => allowed.isEmpty || allowed.contains(a.id))
                      .toList();
                  if (list.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(32),
                      child: Tr(
                        'No accounts available',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final a = list[i];
                      final isDebitCard = a.linkedAccountId != null;
                      final linkedName = a.linkedAccountId == null
                          ? null
                          : accountMap[a.linkedAccountId]?.name;
                      return AppListTile(
                        leading: _iconCircle(a.iconKey, a.colorValue),
                        title: Text(a.name),
                        subtitle: isDebitCard
                            ? Text(tr('Draws from {0}', [linkedName ?? tr('linked bank')]))
                            : null,
                        trailing: isDebitCard
                            ? null
                            : BalanceText(a.currentBalance),
                        onTap: () => Navigator.of(context).pop(a.id),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet: pick a category, as a grid of coloured chips. Only shown for
/// income/expense — a transfer has no category.
///
/// Two levels deep: the first grid is the top-level categories. Tapping one that
/// has subcategories drills into a second grid of its children (with a "Use
/// [parent]" chip to pick the parent directly); a childless one is picked on the
/// spot. Popping returns the chosen category id.
class _CategoryPickerSheet extends ConsumerStatefulWidget {
  const _CategoryPickerSheet({
    required this.kind,
    this.envelopeAccountId,
    this.modeId,
    this.startAsRefund = false,
  });

  final CategoryKind kind;

  /// Money in only: open on the Refund side, listing spending categories.
  final bool startAsRefund;

  /// Offers what this mode allows, plus its own categories.
  final int? modeId;

  /// Set only for an expense on an Envelope Mode account — shows each
  /// category's remaining envelope balance under its name instead of just
  /// the name.
  final int? envelopeAccountId;

  @override
  ConsumerState<_CategoryPickerSheet> createState() =>
      _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends ConsumerState<_CategoryPickerSheet> {
  /// Non-null while drilled into a parent's subcategories.
  int? _drillParentId;

  /// Money in only: picking a spending category instead — a refund, which
  /// gives back to that category's budget (GitHub #201).
  late bool _refund = widget.startAsRefund;

  bool get _canRefund => widget.kind == CategoryKind.income;

  CategoryKind get _kind => _canRefund && _refund
      ? CategoryKind.expense
      : widget.kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final everyday = ref.watch(categoriesProvider(_kind));
    final catsAsync = widget.modeId == null
        ? everyday
        : everyday.whenData(
            (_) => ref.watch(pickerCategoriesProvider((_kind, widget.modeId))),
          );

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: SafeArea(
        top: false,
        child: catsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              tr('Could not load categories.\n{0}', [e]),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          data: (cats) => _content(theme, cats),
        ),
      ),
    );
  }

  Widget _content(ThemeData theme, List<CategoryRow> cats) {
    if (cats.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Tr(
          'No categories yet',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final childrenByParent = <int, List<CategoryRow>>{};
    for (final c in cats) {
      if (c.parentId != null) {
        (childrenByParent[c.parentId!] ??= []).add(c);
      }
    }

    final drillParent = _drillParentId == null
        ? null
        : cats.where((c) => c.id == _drillParentId).firstOrNull;

    // The list of cells to render, and the header, depend on the level.
    final Widget header;
    final List<Widget> cells;
    if (drillParent == null) {
      header = Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _canRefund && _refund
                  ? tr('Refund to which spending category?')
                  : widget.kind == CategoryKind.income
                  ? tr('Money-in category')
                  : tr('Category'),
              style: theme.textTheme.titleLarge,
            ),
            if (_canRefund) ...[
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                key: const Key('category-picker-refund'),
                segments: const [
                  ButtonSegment(value: false, label: Tr('Money in')),
                  ButtonSegment(value: true, label: Tr('Refund')),
                ],
                selected: {_refund},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  _refund = s.first;
                  _drillParentId = null;
                }),
              ),
              if (_refund) ...[
                const SizedBox(height: 8),
                Tr(
                  'Money back from a purchase. It gives back to that '
                  "category's budget. Link it to the purchase afterwards "
                  "to count it in the purchase's month.",
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ],
        ),
      );
      cells = [
        for (final c in cats.where((c) => c.parentId == null))
          _cell(
            theme,
            categoryId: c.id,
            iconKey: c.iconKey,
            colorValue: c.colorValue,
            label: c.name,
            hasChildren: (childrenByParent[c.id]?.isNotEmpty) ?? false,
            onTap: () {
              if ((childrenByParent[c.id]?.isNotEmpty) ?? false) {
                setState(() => _drillParentId = c.id);
              } else {
                Navigator.of(context).pop(c.id);
              }
            },
          ),
      ];
    } else {
      header = Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 20, 12),
        child: Row(
          children: [
            IconButton(
              icon: const AppIcon(Icons.arrow_back),
              tooltip: tr('All categories'),
              onPressed: () => setState(() => _drillParentId = null),
            ),
            Expanded(
              child: Text(
                drillParent.name,
                style: theme.textTheme.titleLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
      cells = [
        // Pick the parent itself, not one of its children.
        _cell(
          theme,
          categoryId: drillParent.id,
          iconKey: drillParent.iconKey,
          colorValue: drillParent.colorValue,
          label: tr('All {0}', [drillParent.name]),
          onTap: () => Navigator.of(context).pop(drillParent.id),
        ),
        for (final c in childrenByParent[drillParent.id] ?? const [])
          _cell(
            theme,
            categoryId: c.id,
            iconKey: c.iconKey,
            colorValue: c.colorValue,
            label: c.name,
            onTap: () => Navigator.of(context).pop(c.id),
          ),
      ];
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Flexible(
          child: GridView.count(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            crossAxisCount: 4,
            mainAxisSpacing: 16,
            crossAxisSpacing: 12,
            // A little shorter when an envelope-balance line is also
            // rendered under the label, so it never clips.
            childAspectRatio: widget.envelopeAccountId == null ? 0.78 : 0.64,
            children: cells,
          ),
        ),
      ],
    );
  }

  /// One tappable category chip. A small dot marks a parent that opens into
  /// subcategories rather than being picked directly. When [categoryId]
  /// names a category and the sheet was opened for an Envelope Mode account,
  /// a second line shows that category's remaining balance in this account.
  Widget _cell(
    ThemeData theme, {
    required int categoryId,
    required String iconKey,
    required int colorValue,
    required String label,
    required VoidCallback onTap,
    bool hasChildren = false,
  }) {
    final envelopeAccountId = widget.envelopeAccountId;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              _iconCircle(iconKey, colorValue, size: 52),
              if (hasChildren)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: AppIcon(
                      Icons.more_horiz_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (envelopeAccountId != null)
            Consumer(
              builder: (context, ref, _) {
                final balance = ref.watch(categoryBalanceProvider(categoryId));
                return Text(
                  tr('{0} left', [MoneyFormat.symbol(balance)]),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    color: balance.isNegative
                        ? AppColors.expense
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class CalculatorKeypadGrid extends AmountKeypadGrid {
  const CalculatorKeypadGrid({
    required super.onDigit,
    required super.onBackspace,
    required this.onOperator,
    required this.onSubmit,
    required this.onMore,
    required this.onCurrency,
    super.key,
  });

  final ValueChanged<String> onOperator;
  final VoidCallback onSubmit;
  final VoidCallback onMore;
  final VoidCallback onCurrency;

  @override
  Widget build(BuildContext context) {
    const keyHeight = 54.0;
    const spacing = 6.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Columns 1-4
        Expanded(
          flex: 4,
          child: Column(
            children: [
              // Row 1: ÷, 7, 8, 9
              Row(
                children: [
                  Expanded(
                    child: _calcKey(
                      context,
                      '÷',
                      () => onOperator('÷'),
                      height: keyHeight,
                      isOp: true,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '7',
                      () => onDigit('7'),
                      height: keyHeight,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '8',
                      () => onDigit('8'),
                      height: keyHeight,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '9',
                      () => onDigit('9'),
                      height: keyHeight,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: spacing),
              // Row 2: ×, 4, 5, 6
              Row(
                children: [
                  Expanded(
                    child: _calcKey(
                      context,
                      '×',
                      () => onOperator('×'),
                      height: keyHeight,
                      isOp: true,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '4',
                      () => onDigit('4'),
                      height: keyHeight,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '5',
                      () => onDigit('5'),
                      height: keyHeight,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '6',
                      () => onDigit('6'),
                      height: keyHeight,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: spacing),
              // Row 3: -, 1, 2, 3
              Row(
                children: [
                  Expanded(
                    child: _calcKey(
                      context,
                      '-',
                      () => onOperator('-'),
                      height: keyHeight,
                      isOp: true,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '1',
                      () => onDigit('1'),
                      height: keyHeight,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '2',
                      () => onDigit('2'),
                      height: keyHeight,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '3',
                      () => onDigit('3'),
                      height: keyHeight,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: spacing),
              // Row 4: +, ₹, 0, .
              Row(
                children: [
                  Expanded(
                    child: _calcKey(
                      context,
                      '+',
                      () => onOperator('+'),
                      height: keyHeight,
                      isOp: true,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '₹',
                      onCurrency,
                      height: keyHeight,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '0',
                      () => onDigit('0'),
                      height: keyHeight,
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _calcKey(
                      context,
                      '.',
                      () => onDigit('.'),
                      height: keyHeight,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: spacing),
        // Column 5: ⌫, ⋯, and tall ✓
        Expanded(
          flex: 1,
          child: Column(
            children: [
              _calcIconKey(
                context,
                Icons.backspace_outlined,
                onBackspace,
                height: keyHeight,
              ),
              const SizedBox(height: spacing),
              _calcIconKey(
                context,
                Icons.more_horiz_rounded,
                onMore,
                height: keyHeight,
              ),
              const SizedBox(height: spacing),
              _submitKey(
                context,
                onSubmit,
                height: (keyHeight * 2) + spacing,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _calcKey(
    BuildContext context,
    String label,
    VoidCallback onTap, {
    required double height,
    bool isOp = false,
  }) {
    final theme = Theme.of(context);
    return _KeyBase(
      height: height,
      color: isOp
          ? theme.colorScheme.surfaceContainer
          : theme.colorScheme.surfaceContainerHighest,
      onTap: onTap,
      child: Center(
        child: Text(
          label,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: isOp ? 20 : 18,
          ),
        ),
      ),
    );
  }

  Widget _calcIconKey(
    BuildContext context,
    IconData icon,
    VoidCallback onTap, {
    required double height,
  }) {
    final theme = Theme.of(context);
    return _KeyBase(
      height: height,
      color: theme.colorScheme.surfaceContainerHighest,
      onTap: onTap,
      child: Center(
        child: AppIcon(icon, size: 22, color: theme.colorScheme.onSurface),
      ),
    );
  }

  Widget _submitKey(
    BuildContext context,
    VoidCallback onTap, {
    required double height,
  }) {
    final theme = Theme.of(context);
    return _KeyBase(
      height: height,
      color: theme.colorScheme.primaryContainer,
      onTap: onTap,
      child: Center(
        child: AppIcon(
          Icons.check_rounded,
          size: 32,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _KeyBase extends StatefulWidget {
  const _KeyBase({
    required this.child,
    required this.height,
    required this.color,
    required this.onTap,
  });

  final Widget child;
  final double height;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_KeyBase> createState() => _KeyBaseState();
}

class _KeyBaseState extends State<_KeyBase> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Material(
          color: widget.color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              HapticFeedback.lightImpact();
              widget.onTap();
            },
            child: SizedBox(
              height: widget.height,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
