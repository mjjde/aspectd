// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:front_end/src/fasta/kernel/kernel_ast_api.dart';

import 'aop_iteminfo.dart';
import 'aop_mode.dart';
import 'aop_utils.dart';

class AopCallImplTransformer extends Transformer {
  AopCallImplTransformer(
      this._aopItemInfoList, this._libraryMap, this._uriToSource);

  final List<AopItemInfo> _aopItemInfoList;
  final Map<String, Library> _libraryMap;
  Library _curLibrary;
  final Map<Uri, Source> _uriToSource;
  final Map<InvocationExpression, InvocationExpression>
      _invocationExpressionMapping =
      <InvocationExpression, InvocationExpression>{};

  @override
  Library visitLibrary(Library node) {
    _curLibrary = node;
    node.transformChildren(this);
    return node;
  }

  @override
  InvocationExpression visitConstructorInvocation(
      ConstructorInvocation constructorInvocation) {
    constructorInvocation.transformChildren(this);
    final Node node = constructorInvocation.targetReference?.node;
    if (node is Constructor) {
      final Constructor constructor = node;
      final Class cls = constructor.parent;
      final String procedureImportUri = cls.reference.canonicalName.parent.name;
      String functionName = '${cls.name}';
      if (constructor.name.name.isNotEmpty) {
        functionName += '.${constructor.name.name}';
      }
      final AopItemInfo aopItemInfo = _filterAopItemInfo(
          _aopItemInfoList, procedureImportUri, cls.name, functionName, true);
      if (aopItemInfo?.mode == AopMode.Call &&
          AopUtils.checkIfSkipAOP(aopItemInfo, _curLibrary) == false) {
        return transformConstructorInvocation(
            constructorInvocation, aopItemInfo);
      }
    } else {
      return constructorInvocation;
    }
    return constructorInvocation;
  }

  @override
  StaticInvocation visitStaticInvocation(StaticInvocation staticInvocation) {
    staticInvocation.transformChildren(this);
    Node node = staticInvocation.targetReference?.node;
    if (node == null) {
      final String procedureName =
          staticInvocation?.targetReference?.canonicalName?.name;
      String tempName = staticInvocation
          ?.targetReference?.canonicalName?.parent?.parent?.name;
      if (tempName == '@methods') {
        tempName = staticInvocation
            ?.targetReference?.canonicalName?.parent?.parent?.parent?.name;
      }
      //Library Static
      if ((procedureName?.length ?? 0) > 0 &&
          tempName != null &&
          tempName.isNotEmpty &&
          _libraryMap[tempName] != null) {
        final Library originalLibrary = _libraryMap[tempName];
        for (Procedure procedure in originalLibrary.procedures) {
          if (procedure.name.name == procedureName) {
            node = procedure;
          }
        }
      }
      // Class Static
      else {
        tempName = staticInvocation
            ?.targetReference?.canonicalName?.parent?.parent?.parent?.name;
        final String clsName = staticInvocation
            ?.targetReference?.canonicalName?.parent?.parent?.name;
        final Library originalLibrary = _libraryMap[tempName];
        for (Class cls in originalLibrary.classes) {
          for (Procedure procedure in cls.procedures) {
            if (cls.name == clsName && procedure.name.name == procedureName) {
              node = procedure;
            }
          }
        }
      }
    }
    if (node is Procedure) {
      final Procedure procedure = node;
      final TreeNode treeNode = procedure.parent;
      if (treeNode is Library) {
        final Library library = treeNode;
        final String libraryImportUri = library.importUri.toString();
        final AopItemInfo aopItemInfo = _filterAopItemInfo(
            _aopItemInfoList, libraryImportUri, '', procedure.name.name, true);
        if (aopItemInfo?.mode == AopMode.Call &&
            AopUtils.checkIfSkipAOP(aopItemInfo, _curLibrary) == false) {
          return transformLibraryStaticMethodInvocation(
              staticInvocation, procedure, aopItemInfo);
        }
      } else if (treeNode is Class) {
        final Class cls = treeNode;
        final String procedureImportUri =
            cls.reference.canonicalName.parent.name;
        final AopItemInfo aopItemInfo = _filterAopItemInfo(_aopItemInfoList,
            procedureImportUri, cls.name, procedure.name.name, true);
        if (aopItemInfo?.mode == AopMode.Call &&
            AopUtils.checkIfSkipAOP(aopItemInfo, _curLibrary) == false) {
          return transformClassStaticMethodInvocation(
              staticInvocation, aopItemInfo);
        }
      }
    } else {
      assert(false);
    }
    return staticInvocation;
  }

  @override
  MethodInvocation visitMethodInvocation(MethodInvocation methodInvocation) {
    methodInvocation.transformChildren(this);
    final Node node = methodInvocation.interfaceTargetReference?.node;
    if (node is Procedure) {
      final String nodeName = node.name.name;
      print(nodeName);
    }

    String importUri, clsName, methodName;
    if (node is Procedure || node == null) {
      if (node is Procedure) {
        final Procedure procedure = node;
        final Class cls = procedure.parent;
        importUri = cls.reference.canonicalName.parent.name;
        clsName = cls.name;
        methodName = methodInvocation.name.name;
      } else if (node == null) {
        importUri = methodInvocation?.interfaceTargetReference?.canonicalName
            ?.reference?.canonicalName?.nonRootTop?.name;
        clsName = methodInvocation
            ?.interfaceTargetReference?.canonicalName?.parent?.parent?.name;
        methodName =
            methodInvocation?.interfaceTargetReference?.canonicalName?.name;
      }
      if (importUri?.contains('example') ?? false) {
        print('');
      }
      final AopItemInfo aopItemInfo = _filterAopItemInfo(
          _aopItemInfoList, importUri, clsName, methodName, false);
      if (aopItemInfo?.mode == AopMode.Call &&
          AopUtils.checkIfSkipAOP(aopItemInfo, _curLibrary) == false) {
        return transformInstanceMethodInvocation(methodInvocation, aopItemInfo);
      }
    }
    return methodInvocation;
  }

  //Filter AopInfoMap for specific callsite.
  AopItemInfo _filterAopItemInfo(List<AopItemInfo> aopItemInfoList,
      String importUri, String clsName, String methodName, bool isStatic) {
    //Reverse sorting so that the newly added Aspect might override the older ones.
    importUri ??= '';
    clsName ??= '';
    methodName ??= '';
    final int aopItemInfoCnt = aopItemInfoList.length;
    for (int i = aopItemInfoCnt - 1; i >= 0; i--) {
      final AopItemInfo aopItemInfo = aopItemInfoList[i];
      if (aopItemInfo.isRegex) {
        if (RegExp(aopItemInfo.importUri).hasMatch(importUri) &&
            RegExp(aopItemInfo.clsName).hasMatch(clsName) &&
            RegExp(aopItemInfo.methodName).hasMatch(methodName) &&
            isStatic == aopItemInfo.isStatic) {
          return aopItemInfo;
        }
      } else {
        if (aopItemInfo.importUri == importUri &&
            aopItemInfo.clsName == clsName &&
            aopItemInfo.methodName == methodName &&
            isStatic == aopItemInfo.isStatic) {
          return aopItemInfo;
        }
      }
    }
    return null;
  }

  //Library Static Method Invocation
  StaticInvocation transformLibraryStaticMethodInvocation(
      StaticInvocation staticInvocation,
      Procedure procedure,
      AopItemInfo aopItemInfo) {
    assert(aopItemInfo.mode != null);

    if (_invocationExpressionMapping[staticInvocation] != null) {
      return _invocationExpressionMapping[staticInvocation];
    }

    final Library procedureLibrary = procedure.parent;

    final String stubKey =
        '${AopUtils.kAopStubMethodPrefix}${AopUtils.kPrimaryKeyAopMethod}';
    AopUtils.kPrimaryKeyAopMethod++;

    //更改原始调用
    final Arguments redirectArguments = Arguments.empty();
    final Map<String, String> sourceInfo = AopUtils.calcSourceInfo(
        _uriToSource, _curLibrary, staticInvocation.fileOffset);
    AopUtils.concatArgumentsForAopMethod(
        sourceInfo,
        redirectArguments,
        stubKey,
        StringLiteral(procedureLibrary.importUri.toString()),
        procedure,
        staticInvocation.arguments);
    final StaticInvocation staticInvocationNew =
        StaticInvocation(aopItemInfo.aopMember, redirectArguments);

    insertStaticMethod4Pointcut(
        aopItemInfo,
        stubKey,
        AopUtils.pointCutProceedProcedure.parent,
        staticInvocation,
        procedureLibrary,
        procedure);
    _invocationExpressionMapping[staticInvocation] = staticInvocationNew;
    return staticInvocationNew;
  }

  //Class Constructor Invocation
  StaticInvocation transformConstructorInvocation(
      ConstructorInvocation constructorInvocation, AopItemInfo aopItemInfo) {
    assert(aopItemInfo.mode != null);

    if (_invocationExpressionMapping[constructorInvocation] != null) {
      return _invocationExpressionMapping[constructorInvocation];
    }

    final Constructor constructor = constructorInvocation.targetReference.node;
    final Class procedureClass = constructor.parent;

    final String stubKey =
        '${AopUtils.kAopStubMethodPrefix}${AopUtils.kPrimaryKeyAopMethod}';
    AopUtils.kPrimaryKeyAopMethod++;

    //更改原始调用
    final Arguments redirectArguments = Arguments.empty();
    final Map<String, String> sourceInfo = AopUtils.calcSourceInfo(
        _uriToSource, _curLibrary, constructorInvocation.fileOffset);
    AopUtils.concatArgumentsForAopMethod(
        sourceInfo,
        redirectArguments,
        stubKey,
        StringLiteral(procedureClass.name),
        constructor,
        constructorInvocation.arguments);

    final StaticInvocation staticInvocationNew =
        StaticInvocation(aopItemInfo.aopMember, redirectArguments);

    insertConstructor4Pointcut(
        aopItemInfo,
        stubKey,
        AopUtils.pointCutProceedProcedure.parent,
        constructorInvocation,
        constructorInvocation.targetReference.node.parent.parent,
        constructor);
    _invocationExpressionMapping[constructorInvocation] = staticInvocationNew;
    return staticInvocationNew;
  }

  //Class Static Method Invocation
  StaticInvocation transformClassStaticMethodInvocation(
      StaticInvocation staticInvocation, AopItemInfo aopItemInfo) {
    assert(aopItemInfo.mode != null);

    if (_invocationExpressionMapping[staticInvocation] != null) {
      return _invocationExpressionMapping[staticInvocation];
    }

    final Procedure procedure = staticInvocation.targetReference.node;
    final Class procedureClass = procedure.parent;

    final String stubKey =
        '${AopUtils.kAopStubMethodPrefix}${AopUtils.kPrimaryKeyAopMethod}';
    AopUtils.kPrimaryKeyAopMethod++;

    //更改原始调用
    final Arguments redirectArguments = Arguments.empty();
    final Map<String, String> sourceInfo = AopUtils.calcSourceInfo(
        _uriToSource, _curLibrary, staticInvocation.fileOffset);
    AopUtils.concatArgumentsForAopMethod(
        sourceInfo,
        redirectArguments,
        stubKey,
        StringLiteral(procedureClass.name),
        procedure,
        staticInvocation.arguments);

    final StaticInvocation staticInvocationNew =
        StaticInvocation(aopItemInfo.aopMember, redirectArguments);

    insertStaticMethod4Pointcut(
        aopItemInfo,
        stubKey,
        AopUtils.pointCutProceedProcedure.parent,
        staticInvocation,
        staticInvocation.targetReference.node.parent.parent,
        procedure);
    _invocationExpressionMapping[staticInvocation] = staticInvocationNew;
    return staticInvocationNew;
  }

  //Instance Method Invocation
  MethodInvocation transformInstanceMethodInvocation(
      MethodInvocation methodInvocation, AopItemInfo aopItemInfo) {
    assert(aopItemInfo.mode != null);

    if (_invocationExpressionMapping[methodInvocation] != null) {
      return _invocationExpressionMapping[methodInvocation];
    }

    Procedure methodProcedure = methodInvocation.interfaceTargetReference.node;
    Class methodClass =
        methodInvocation?.interfaceTargetReference?.node?.parent;
    Class methodImplClass = methodClass;
    final String procedureName = methodInvocation?.name?.name;
    Library originalLibrary = methodProcedure?.parent?.parent;
    if (originalLibrary == null) {
      final String libImportUri = methodInvocation
          ?.interfaceTargetReference?.canonicalName?.nonRootTop?.name;
      originalLibrary = _libraryMap[libImportUri];
    }
    if (methodClass == null) {
      final String expectedName = methodInvocation
          ?.interfaceTargetReference?.canonicalName?.parent?.parent?.name;
      for (Class cls in originalLibrary.classes) {
        if (cls.name == expectedName) {
          methodClass = cls;
          break;
        }
      }
    }

    if (methodClass.flags & Class.FlagAbstract != 0) {
      for (Class cls in originalLibrary.classes) {
        final String clsName = cls.name;
        if (cls.flags & Class.FlagAbstract != 0) //抽象类
          continue;
        if (methodClass.flags & Class.FlagAbstract != 0) {
          bool matches = false;
          for (Supertype superType in cls.implementedTypes) {
            if (superType.className.node == methodClass) {
              matches = true;
            }
          }
          if (!matches || (clsName != '_${methodClass.name}')) {
            continue;
          }
        } else if (clsName != methodClass.name) {
          continue;
        }
        methodImplClass = cls;
        for (Procedure procedure in cls.procedures) {
          final String methodName = procedure.name.name;
          if (methodName == procedureName) {
            methodProcedure = procedure;
            break;
          }
        }
      }
    }

    final String stubKey =
        '${AopUtils.kAopStubMethodPrefix}${AopUtils.kPrimaryKeyAopMethod}';
    AopUtils.kPrimaryKeyAopMethod++;

    //更改原始调用
    final Arguments redirectArguments = Arguments.empty();
    final Map<String, String> sourceInfo = AopUtils.calcSourceInfo(
        _uriToSource, _curLibrary, methodInvocation.fileOffset);
    AopUtils.concatArgumentsForAopMethod(sourceInfo, redirectArguments, stubKey,
        methodInvocation.receiver, methodProcedure, methodInvocation.arguments);

    final Class cls = aopItemInfo.aopMember.parent;
    final ConstructorInvocation redirectConstructorInvocation =
        ConstructorInvocation.byReference(
            cls.constructors.first.reference, Arguments(<Expression>[]));
    final MethodInvocation methodInvocationNew = MethodInvocation(
        redirectConstructorInvocation,
        aopItemInfo.aopMember.name,
        redirectArguments);
    AopUtils.insertLibraryDependency(
        _curLibrary, aopItemInfo.aopMember.parent.parent);

    insertInstanceMethod4Pointcut(
        aopItemInfo,
        stubKey,
        AopUtils.pointCutProceedProcedure.parent,
        methodImplClass,
        methodProcedure);
    _invocationExpressionMapping[methodInvocation] = methodInvocationNew;
    return methodInvocationNew;
  }

  bool insertConstructor4Pointcut(
      AopItemInfo aopItemInfo,
      String stubKey,
      Class pointCutClass,
      ConstructorInvocation constructorInvocation,
      Library originalLibrary,
      Member originalMember) {
    //Add library dependency
    AopUtils.insertLibraryDependency(pointCutClass.parent, originalLibrary);
    //Add new Procedure
    final ConstructorInvocation constructorInvocation = ConstructorInvocation(
        originalMember,
        AopUtils.concatArguments4PointcutStubCall(originalMember));
    final bool shouldReturn = !(originalMember.function.returnType is VoidType);
    createPointcutStubProcedure(
        aopItemInfo,
        stubKey,
        pointCutClass,
        AopUtils.createProcedureBodyWithExpression(
            constructorInvocation, shouldReturn),
        shouldReturn);
    return true;
  }

  bool insertStaticMethod4Pointcut(
      AopItemInfo aopItemInfo,
      String stubKey,
      Class pointCutClass,
      StaticInvocation originalStaticInvocation,
      Library originalLibrary,
      Member originalMember) {
    //Add library dependency
    AopUtils.insertLibraryDependency(pointCutClass.parent, originalLibrary);
    //Add new Procedure
    final StaticInvocation staticInvocation = StaticInvocation(originalMember,
        AopUtils.concatArguments4PointcutStubCall(originalMember),
        isConst: originalMember.isConst);
    final bool shouldReturn = !(originalMember.function.returnType is VoidType);
    createPointcutStubProcedure(
        aopItemInfo,
        stubKey,
        pointCutClass,
        AopUtils.createProcedureBodyWithExpression(
            staticInvocation, shouldReturn),
        shouldReturn);
    return true;
  }

  bool insertInstanceMethod4Pointcut(AopItemInfo aopItemInfo, String stubKey,
      Class pointCutClass, Class procedureImpl, Procedure originalProcedure) {
    //Add library dependency
    //Add new Procedure
    final DirectMethodInvocation mockedInvocation = DirectMethodInvocation(
        AsExpression(PropertyGet(ThisExpression(), Name('target')),
            InterfaceType(procedureImpl, Nullability.legacy)),
        originalProcedure,
        AopUtils.concatArguments4PointcutStubCall(originalProcedure));
    final bool shouldReturn =
        !(originalProcedure.function.returnType is VoidType);
    createPointcutStubProcedure(
        aopItemInfo,
        stubKey,
        pointCutClass,
        AopUtils.createProcedureBodyWithExpression(mockedInvocation,
            !(originalProcedure.function.returnType is VoidType)),
        shouldReturn);
    return true;
  }

  //Will create stub and insert call branch in proceed.
  void createPointcutStubProcedure(AopItemInfo aopItemInfo, String stubKey,
      Class pointCutClass, Statement bodyStatements, bool shouldReturn) {
    final Procedure procedure = AopUtils.createStubProcedure(
        Name(stubKey, AopUtils.pointCutProceedProcedure.name.library),
        aopItemInfo,
        AopUtils.pointCutProceedProcedure,
        bodyStatements,
        shouldReturn);
    pointCutClass.addMember(procedure);
    AopUtils.insertProceedBranch(procedure, shouldReturn);
  }
}
