// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.transformations.async;

import '../kernel.dart';
import '../type_environment.dart';
import 'continuation.dart';

/// A transformer that introduces temporary variables for all subexpressions
/// that are alive across yield points (AwaitExpression).
///
/// The transformer is invoked by passing [rewrite] a top-level expression.
///
/// All intermediate values that are possible live across an await are named in
/// local variables.
///
/// Await expressions are translated into a call to a helper function and a
/// native yield.
class ExpressionLifter extends Transformer {
  final AsyncRewriterBase continuationRewriter;

  /// Have we seen an await to the right in the expression tree.
  ///
  /// Subexpressions are visited right-to-left in the reverse of evaluation
  /// order.
  ///
  /// On entry to an expression's visit method, [seenAwait] indicates whether a
  /// sibling to the right contains an await.  If so the expression will be
  /// named in a temporary variable because it is potentially live across an
  /// await.
  ///
  /// On exit from an expression's visit method, [seenAwait] indicates whether
  /// the expression itself or a sibling to the right contains an await.
  bool seenAwait = false;

  /// The (reverse order) sequence of statements that have been emitted.
  ///
  /// Transformation of an expression produces a transformed expression and a
  /// sequence of statements which are assignments to local variables, calls to
  /// helper functions, and yield points.  Only the yield points need to be a
  /// statements, and they are statements so an implementation does not have to
  /// handle unnamed expression intermediate live across yield points.
  ///
  /// The visit methods return the transformed expression and build a sequence
  /// of statements by emitting statements into this list.  This list is built
  /// in reverse because children are visited right-to-left.
  ///
  /// If an expression should be named it is named before visiting its children
  /// so the naming assignment appears in the list before all statements
  /// implementing the translation of the children.
  ///
  /// Children that are conditionally evaluated, such as some parts of logical
  /// and conditional expressions, must be delimited so that they do not emit
  /// unguarded statements into [statements].  This is implemented by setting
  /// [statements] to a fresh empty list before transforming those children.
  List<Statement> statements = <Statement>[];

  /// The number of currently live named intermediate values.
  ///
  /// This index is used to allocate names to temporary values.  Because
  /// children are visited right-to-left, names are assigned in reverse order of
  /// index.
  ///
  /// When an assignment is emitted into [statements] to name an expression
  /// before visiting its children, the index is not immediately reserved
  /// because a child can freely use the same name as its parent.  In practice,
  /// this will be the rightmost named child.
  ///
  /// After visiting the children of a named expression, [nameIndex] is set to
  /// indicate one more live value (the value of the expression) than before
  /// visiting the expression.
  ///
  /// After visiting the children of an expression that is not named,
  /// [nameIndex] may still account for names of subexpressions.
  int nameIndex = 0;

  final VariableDeclaration asyncResult =
      new VariableDeclaration(':result_or_exception');
  final List<VariableDeclaration> variables = <VariableDeclaration>[];

  ExpressionLifter(this.continuationRewriter);

  StatefulStaticTypeContext get _staticTypeContext =>
      continuationRewriter.staticTypeContext;

  Block blockOf(List<Statement> statements) {
    return new Block(statements.reversed.toList());
  }

  /// Rewrite a toplevel expression (toplevel wrt. a statement).
  ///
  /// Rewriting an expression produces a sequence of statements and an
  /// expression.  The sequence of statements are added to the given list.  Pass
  /// an empty list if the rewritten expression should be delimited from the
  /// surrounding context.
  Expression rewrite(Expression expression, List<Statement> outer) {
    assert(statements.isEmpty);
    var saved = seenAwait;
    seenAwait = false;
    Expression result = transform(expression);
    outer.addAll(statements.reversed);
    statements.clear();
    seenAwait = seenAwait || saved;
    return result;
  }

  // Perform an action with a given list of statements so that it cannot emit
  // statements into the 'outer' list.
  Expression delimit(Expression action(), List<Statement> inner) {
    var outer = statements;
    statements = inner;
    Expression result = action();
    statements = outer;
    return result;
  }

  // Wraps VariableGet in an unsafeCast if `type` isn't dynamic.
  Expression unsafeCastVariableGet(
      VariableDeclaration variable, DartType type) {
    if (type != const DynamicType()) {
      return StaticInvocation(
          continuationRewriter.helper.unsafeCast,
          Arguments(<Expression>[VariableGet(variable)],
              types: <DartType>[type]));
    }
    return VariableGet(variable);
  }

  // Name an expression by emitting an assignment to a temporary variable.
  Expression name(Expression expr) {
    DartType type = expr.getStaticType(_staticTypeContext);
    VariableDeclaration temp = allocateTemporary(nameIndex, type);
    statements.add(ExpressionStatement(VariableSet(temp, expr)));
    // Wrap in unsafeCast to make sure we pass type information even if we later
    // have to re-type the temporary variable to dynamic.
    return unsafeCastVariableGet(temp, type);
  }

  VariableDeclaration allocateTemporary(int index,
      [DartType type = const DynamicType()]) {
    if (variables.length > index) {
      // Re-type temporary to dynamic if we detect reuse with different type.
      // Note: We should make sure all uses use `unsafeCast(...)` to pass their
      // type information on, as that is lost otherwise.
      if (variables[index].type != const DynamicType() &&
          variables[index].type != type) {
        variables[index].type = const DynamicType();
      }
      return variables[index];
    }
    for (var i = variables.length; i <= index; i++) {
      variables.add(VariableDeclaration(":async_temporary_${i}", type: type));
    }
    return variables[index];
  }

  // Simple literals.  These are pure expressions so they can be evaluated after
  // an await to their right.
  @override
  TreeNode visitSymbolLiteral(SymbolLiteral expr) => expr;
  @override
  TreeNode visitTypeLiteral(TypeLiteral expr) => expr;
  @override
  TreeNode visitThisExpression(ThisExpression expr) => expr;
  @override
  TreeNode visitStringLiteral(StringLiteral expr) => expr;
  @override
  TreeNode visitIntLiteral(IntLiteral expr) => expr;
  @override
  TreeNode visitDoubleLiteral(DoubleLiteral expr) => expr;
  @override
  TreeNode visitBoolLiteral(BoolLiteral expr) => expr;
  @override
  TreeNode visitNullLiteral(NullLiteral expr) => expr;

  // Nullary expressions with effects.
  Expression nullary(Expression expr) {
    if (seenAwait) {
      expr = name(expr);
      ++nameIndex;
    }
    return expr;
  }

  @override
  TreeNode visitSuperPropertyGet(SuperPropertyGet expr) => nullary(expr);
  @override
  TreeNode visitStaticGet(StaticGet expr) => nullary(expr);
  @override
  TreeNode visitStaticTearOff(StaticTearOff expr) => nullary(expr);
  @override
  TreeNode visitRethrow(Rethrow expr) => nullary(expr);

  // Getting a final or const variable is not an effect so it can be evaluated
  // after an await to its right.
  @override
  TreeNode visitVariableGet(VariableGet expr) {
    Expression result = expr;
    if (seenAwait && !expr.variable.isFinal && !expr.variable.isConst) {
      result = name(expr);
      ++nameIndex;
    }
    return result;
  }

  // Transform an expression given an action to transform the children.  For
  // this purposes of the await transformer the children should generally be
  // translated from right to left, in the reverse of evaluation order.
  Expression transformTreeNode(Expression expr, void action()) {
    var shouldName = seenAwait;

    // 1. If there is an await in a sibling to the right, emit an assignment to
    // a temporary variable before transforming the children.
    var result = shouldName ? name(expr) : expr;

    // 2. Remember the number of live temporaries before transforming the
    // children.
    var index = nameIndex;

    // 3. Transform the children.  Initially they do not have an await in a
    // sibling to their right.
    seenAwait = false;
    action();

    // 4. If the expression was named then the variables used for children are
    // no longer live but the variable used for the expression is.
    // On the other hand, a sibling to the left (yet to be processed) cannot
    // reuse any of the variables used here, as the assignments in the children
    // (here) would overwrite assignments in the siblings to the left,
    // possibly before the use of the overwritten values.
    if (shouldName) {
      if (index + 1 > nameIndex) nameIndex = index + 1;
      seenAwait = true;
    }
    return result;
  }

  // Unary expressions.
  Expression unary(Expression expr) {
    return transformTreeNode(expr, () {
      expr.transformChildren(this);
    });
  }

  @override
  TreeNode visitInvalidExpression(InvalidExpression expr) => unary(expr);
  @override
  TreeNode visitVariableSet(VariableSet expr) => unary(expr);
  @override
  TreeNode visitInstanceGet(InstanceGet expr) => unary(expr);
  @override
  TreeNode visitDynamicGet(DynamicGet expr) => unary(expr);
  @override
  TreeNode visitInstanceTearOff(InstanceTearOff expr) => unary(expr);
  @override
  TreeNode visitFunctionTearOff(FunctionTearOff expr) => unary(expr);
  @override
  TreeNode visitSuperPropertySet(SuperPropertySet expr) => unary(expr);
  @override
  TreeNode visitStaticSet(StaticSet expr) => unary(expr);
  @override
  TreeNode visitNot(Not expr) => unary(expr);
  @override
  TreeNode visitIsExpression(IsExpression expr) => unary(expr);
  @override
  TreeNode visitAsExpression(AsExpression expr) => unary(expr);
  @override
  TreeNode visitThrow(Throw expr) => unary(expr);

  @override
  TreeNode visitInstanceSet(InstanceSet expr) {
    return transformTreeNode(expr, () {
      expr.value = transform(expr.value)..parent = expr;
      expr.receiver = transform(expr.receiver)..parent = expr;
    });
  }

  @override
  TreeNode visitDynamicSet(DynamicSet expr) {
    return transformTreeNode(expr, () {
      expr.value = transform(expr.value)..parent = expr;
      expr.receiver = transform(expr.receiver)..parent = expr;
    });
  }

  @override
  TreeNode visitArguments(Arguments args) {
    for (var named in args.named.reversed) {
      named.value = transform(named.value)..parent = named;
    }
    var positional = args.positional;
    for (var i = positional.length - 1; i >= 0; --i) {
      positional[i] = transform(positional[i])..parent = args;
    }
    // Returns the arguments, which is assumed at the call sites because they do
    // not replace the arguments or set parent pointers.
    return args;
  }

  @override
  TreeNode visitInstanceInvocation(InstanceInvocation expr) {
    return transformTreeNode(expr, () {
      visitArguments(expr.arguments);
      expr.receiver = transform(expr.receiver)..parent = expr;
    });
  }

  @override
  TreeNode visitLocalFunctionInvocation(LocalFunctionInvocation expr) {
    return transformTreeNode(expr, () {
      visitArguments(expr.arguments);
    });
  }

  @override
  TreeNode visitDynamicInvocation(DynamicInvocation expr) {
    return transformTreeNode(expr, () {
      visitArguments(expr.arguments);
      expr.receiver = transform(expr.receiver)..parent = expr;
    });
  }

  @override
  TreeNode visitFunctionInvocation(FunctionInvocation expr) {
    return transformTreeNode(expr, () {
      visitArguments(expr.arguments);
      expr.receiver = transform(expr.receiver)..parent = expr;
    });
  }

  @override
  TreeNode visitEqualsNull(EqualsNull expr) => unary(expr);

  @override
  TreeNode visitEqualsCall(EqualsCall expr) {
    return transformTreeNode(expr, () {
      expr.right = transform(expr.right)..parent = expr;
      expr.left = transform(expr.left)..parent = expr;
    });
  }

  @override
  TreeNode visitSuperMethodInvocation(SuperMethodInvocation expr) {
    return transformTreeNode(expr, () {
      visitArguments(expr.arguments);
    });
  }

  @override
  TreeNode visitStaticInvocation(StaticInvocation expr) {
    return transformTreeNode(expr, () {
      visitArguments(expr.arguments);
    });
  }

  @override
  TreeNode visitConstructorInvocation(ConstructorInvocation expr) {
    return transformTreeNode(expr, () {
      visitArguments(expr.arguments);
    });
  }

  @override
  TreeNode visitStringConcatenation(StringConcatenation expr) {
    return transformTreeNode(expr, () {
      var expressions = expr.expressions;
      for (var i = expressions.length - 1; i >= 0; --i) {
        expressions[i] = transform(expressions[i])..parent = expr;
      }
    });
  }

  @override
  TreeNode visitListLiteral(ListLiteral expr) {
    return transformTreeNode(expr, () {
      var expressions = expr.expressions;
      for (var i = expressions.length - 1; i >= 0; --i) {
        expressions[i] = transform(expr.expressions[i])..parent = expr;
      }
    });
  }

  @override
  TreeNode visitMapLiteral(MapLiteral expr) {
    return transformTreeNode(expr, () {
      for (var entry in expr.entries.reversed) {
        entry.value = transform(entry.value)..parent = entry;
        entry.key = transform(entry.key)..parent = entry;
      }
    });
  }

  // Control flow.
  @override
  TreeNode visitLogicalExpression(LogicalExpression expr) {
    var shouldName = seenAwait;

    // Right is delimited because it is conditionally evaluated.
    var rightStatements = <Statement>[];
    seenAwait = false;
    expr.right = delimit(() => transform(expr.right), rightStatements)
      ..parent = expr;
    var rightAwait = seenAwait;

    if (rightStatements.isEmpty) {
      // Easy case: right did not emit any statements.
      seenAwait = shouldName;
      return transformTreeNode(expr, () {
        expr.left = transform(expr.left)..parent = expr;
        seenAwait = seenAwait || rightAwait;
      });
    }

    // If right has emitted statements we will produce a temporary t and emit
    // for && (there is an analogous case for ||):
    //
    // t = [left] == true;
    // if (t) {
    //   t = [right] == true;
    // }

    // Recall that statements are emitted in reverse order, so first emit the if
    // statement, then the assignment of [left] == true, and then translate left
    // so any statements it emits occur after in the accumulated list (that is,
    // so they occur before in the corresponding block).
    var rightBody = blockOf(rightStatements);
    final type = _staticTypeContext.typeEnvironment.coreTypes
        .boolRawType(_staticTypeContext.nonNullable);
    final result = allocateTemporary(nameIndex, type);
    final objectEquals = continuationRewriter.helper.coreTypes.objectEquals;
    rightBody.addStatement(new ExpressionStatement(new VariableSet(
        result,
        new EqualsCall(expr.right, new BoolLiteral(true),
            interfaceTarget: objectEquals,
            functionType: objectEquals.getterType as FunctionType))));
    var then, otherwise;
    if (expr.operatorEnum == LogicalExpressionOperator.AND) {
      then = rightBody;
      otherwise = null;
    } else {
      then = new EmptyStatement();
      otherwise = rightBody;
    }
    statements.add(
        new IfStatement(unsafeCastVariableGet(result, type), then, otherwise));

    final test = new EqualsCall(expr.left, new BoolLiteral(true),
        interfaceTarget: objectEquals,
        functionType: objectEquals.getterType as FunctionType);
    statements.add(new ExpressionStatement(new VariableSet(result, test)));

    seenAwait = false;
    test.left = transform(test.left)..parent = test;

    ++nameIndex;
    seenAwait = seenAwait || rightAwait;
    return unsafeCastVariableGet(result, type);
  }

  @override
  TreeNode visitConditionalExpression(ConditionalExpression expr) {
    // Then and otherwise are delimited because they are conditionally
    // evaluated.
    var shouldName = seenAwait;

    final savedNameIndex = nameIndex;

    var thenStatements = <Statement>[];
    seenAwait = false;
    expr.then = delimit(() => transform(expr.then), thenStatements)
      ..parent = expr;
    var thenAwait = seenAwait;

    final thenNameIndex = nameIndex;
    nameIndex = savedNameIndex;

    var otherwiseStatements = <Statement>[];
    seenAwait = false;
    expr.otherwise =
        delimit(() => transform(expr.otherwise), otherwiseStatements)
          ..parent = expr;
    var otherwiseAwait = seenAwait;

    // Only one side of this branch will get executed at a time, so just make
    // sure we have enough temps for either, not both at the same time.
    if (thenNameIndex > nameIndex) {
      nameIndex = thenNameIndex;
    }

    if (thenStatements.isEmpty && otherwiseStatements.isEmpty) {
      // Easy case: neither then nor otherwise emitted any statements.
      seenAwait = shouldName;
      return transformTreeNode(expr, () {
        expr.condition = transform(expr.condition)..parent = expr;
        seenAwait = seenAwait || thenAwait || otherwiseAwait;
      });
    }

    // If `then` or `otherwise` has emitted statements we will produce a
    // temporary t and emit:
    //
    // if ([condition]) {
    //   t = [left];
    // } else {
    //   t = [right];
    // }
    final result = allocateTemporary(nameIndex, expr.staticType);
    var thenBody = blockOf(thenStatements);
    var otherwiseBody = blockOf(otherwiseStatements);
    thenBody.addStatement(
        new ExpressionStatement(new VariableSet(result, expr.then)));
    otherwiseBody.addStatement(
        new ExpressionStatement(new VariableSet(result, expr.otherwise)));
    var branch = new IfStatement(expr.condition, thenBody, otherwiseBody);
    statements.add(branch);

    seenAwait = false;
    branch.condition = transform(branch.condition)..parent = branch;

    ++nameIndex;
    seenAwait = seenAwait || thenAwait || otherwiseAwait;
    return unsafeCastVariableGet(result, expr.staticType);
  }

  // Others.
  @override
  TreeNode visitAwaitExpression(AwaitExpression expr) {
    final R = continuationRewriter;
    var shouldName = seenAwait;
    var type = expr.getStaticType(_staticTypeContext);
    Expression result = unsafeCastVariableGet(asyncResult, type);

    // The statements are in reverse order, so name the result first if
    // necessary and then add the two other statements in reverse.
    if (shouldName) result = name(result);
    Arguments arguments = new Arguments(<Expression>[
      expr.operand,
      new VariableGet(R.thenContinuationVariable),
      new VariableGet(R.catchErrorContinuationVariable),
    ]);

    // We are building
    //
    //     [yield] (let _ = _awaitHelper(...) in null)
    //
    // to ensure that :await_jump_var and :await_jump_ctx are updated
    // before _awaitHelper is invoked (see BuildYieldStatement in
    // StreamingFlowGraphBuilder for details of how [yield] is translated to
    // IL). This guarantees that recursive invocation of the current function
    // would continue from the correct "jump" position. Recursive invocations
    // arise if future we are awaiting completes synchronously. Builtin Future
    // implementation don't complete synchronously, but Flutter's
    // SynchronousFuture do (see bug http://dartbug.com/32098 for more details).
    statements.add(R.createContinuationPoint(new Let(
        new VariableDeclaration(null,
            initializer: new StaticInvocation(R.helper.awaitHelper, arguments)
              ..fileOffset = expr.fileOffset),
        new NullLiteral()))
      ..fileOffset = expr.fileOffset);

    seenAwait = false;
    var index = nameIndex;
    arguments.positional[0] = transform(expr.operand)..parent = arguments;

    if (shouldName && index + 1 > nameIndex) nameIndex = index + 1;
    seenAwait = true;
    return result;
  }

  @override
  TreeNode visitFunctionExpression(FunctionExpression expr) {
    expr.transformChildren(this);
    return expr;
  }

  @override
  TreeNode visitLet(Let expr) {
    var body = transform(expr.body);

    VariableDeclaration variable = expr.variable;
    if (seenAwait) {
      // There is an await in the body of `let var x = initializer in body` or
      // to its right.  We will produce the sequence of statements:
      //
      // <initializer's statements>
      // var x = <initializer's value>
      // <body's statements>
      //
      // and return the body's value.
      //
      // So x is in scope for all the body's statements and the body's value.
      // This has the unpleasant consequence that all let-bound variables with
      // await in the let's body will end up hoisted out of the expression and
      // allocated to the context in the VM, even if they have no uses
      // (`let _ = e0 in e1` can be used for sequencing of `e0` and `e1`).
      statements.add(variable);
      var index = nameIndex;
      seenAwait = false;
      variable.initializer = transform(variable.initializer!)
        ..parent = variable;
      // Temporaries used in the initializer or the body are not live but the
      // temporary used for the body is.
      if (index + 1 > nameIndex) nameIndex = index + 1;
      seenAwait = true;
      return body;
    } else {
      // The body in `let x = initializer in body` did not contain an await.  We
      // can leave a let expression.
      return transformTreeNode(expr, () {
        // The body has already been translated.
        expr.body = body..parent = expr;
        variable.initializer = transform(variable.initializer!)
          ..parent = variable;
      });
    }
  }

  @override
  TreeNode visitFunctionNode(FunctionNode node) {
    var nestedRewriter = new RecursiveContinuationRewriter(
        continuationRewriter.helper, _staticTypeContext);
    return nestedRewriter.transform(node);
  }

  @override
  TreeNode visitBlockExpression(BlockExpression expr) {
    return transformTreeNode(expr, () {
      expr.value = transform(expr.value)..parent = expr;
      List<Statement> body = <Statement>[];
      for (Statement stmt in expr.body.statements.reversed) {
        Statement? translation = _rewriteStatement(stmt);
        if (translation != null) body.add(translation);
      }
      expr.body = new Block(body.reversed.toList())..parent = expr;
    });
  }

  Statement? _rewriteStatement(Statement stmt) {
    // This method translates a statement nested in an expression (e.g., in a
    // block expression).  It produces a translated statement, a list of
    // statements which are side effects necessary for any await, and a flag
    // indicating whether there was an await in the statement or to its right.
    // The translated statement can be null in the case where there was already
    // an await to the right.

    // The translation is accumulating two lists of statements, an inner list
    // which is a reversed list of effects needed for the current expression and
    // an outer list which represents the block containing the current
    // statement.  We need to preserve both of those from side effects.
    List<Statement> savedInner = statements;
    List<Statement> savedOuter = continuationRewriter.statements;
    statements = <Statement>[];
    continuationRewriter.statements = <Statement>[];
    continuationRewriter.transform(stmt);

    List<Statement> results = continuationRewriter.statements;
    statements = savedInner;
    continuationRewriter.statements = savedOuter;
    if (!seenAwait && results.length == 1) return results.first;
    statements.addAll(results.reversed);
    return null;
  }

  @override
  TreeNode defaultStatement(Statement stmt) {
    throw new UnsupportedError(
        "Use _rewriteStatement to transform statement: ${stmt}");
  }
}
