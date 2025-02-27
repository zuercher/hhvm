/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010-present Facebook, Inc. (http://www.facebook.com)  |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | http://www.php.net/license/3_01.txt                                  |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
*/

#include "hphp/runtime/vm/jit/ir-instruction.h"

#include "hphp/runtime/base/repo-auth-type.h"
#include "hphp/runtime/base/repo-auth-type-array.h"
#include "hphp/runtime/vm/func.h"

#include "hphp/runtime/vm/jit/analysis.h"
#include "hphp/runtime/vm/jit/block.h"
#include "hphp/runtime/vm/jit/edge.h"
#include "hphp/runtime/vm/jit/extra-data.h"
#include "hphp/runtime/vm/jit/irgen-builtin.h"
#include "hphp/runtime/vm/jit/irgen-call.h"
#include "hphp/runtime/vm/jit/ir-instr-table.h"
#include "hphp/runtime/vm/jit/ir-opcode.h"
#include "hphp/runtime/vm/jit/minstr-effects.h"
#include "hphp/runtime/vm/jit/print.h"
#include "hphp/runtime/vm/jit/simplify.h"
#include "hphp/runtime/vm/jit/ssa-tmp.h"
#include "hphp/runtime/vm/jit/type-array-elem.h"
#include "hphp/runtime/vm/jit/type.h"

#include "hphp/runtime/ext/asio/ext_async-function-wait-handle.h"
#include "hphp/runtime/ext/asio/ext_async-generator.h"
#include "hphp/runtime/ext/asio/ext_async-generator-wait-handle.h"
#include "hphp/runtime/ext/asio/ext_await-all-wait-handle.h"
#include "hphp/runtime/ext/asio/ext_static-wait-handle.h"
#include "hphp/runtime/ext/functioncredential/ext_functioncredential.h"
#include "hphp/runtime/ext/generator/ext_generator.h"

#include "hphp/util/arena.h"

#include <folly/Range.h>

#include <algorithm>
#include <sstream>

namespace HPHP { namespace jit {
//////////////////////////////////////////////////////////////////////

IRInstruction::IRInstruction(Arena& arena, const IRInstruction* inst, Id id)
  : m_typeParam(inst->m_typeParam)
  , m_op(inst->m_op)
  , m_iroff(inst->m_iroff)
  , m_numSrcs(inst->m_numSrcs)
  , m_numDsts(inst->m_numDsts)
  , m_hasTypeParam{inst->m_hasTypeParam}
  , m_marker(inst->m_marker)
  , m_id(id)
  , m_srcs(m_numSrcs ? new (arena) SSATmp*[m_numSrcs] : nullptr)
  , m_dest(nullptr)
  , m_extra(inst->m_extra ? cloneExtra(op(), inst->m_extra, arena)
                          : nullptr)
{
  assertx(!isTransient());
  std::copy(inst->m_srcs, inst->m_srcs + inst->m_numSrcs, m_srcs);
  if (hasEdges()) {
    m_edges = new (arena) Edge[2];
    m_edges[0].setInst(this);
    m_edges[0].setTo(inst->next());
    m_edges[1].setInst(this);
    m_edges[1].setTo(inst->taken());
  } else {
    m_edges = nullptr;
  }
}

std::string IRInstruction::toString() const {
  std::ostringstream str;
  print(str, this);
  return str.str();
}

///////////////////////////////////////////////////////////////////////////////

void IRInstruction::convertToNop() {
  if (hasEdges()) clearEdges();
  IRInstruction nop(Nop, bcctx());
  m_op           = nop.m_op;
  m_typeParam    = nop.m_typeParam;
  m_numSrcs      = nop.m_numSrcs;
  m_srcs         = nop.m_srcs;
  m_numDsts      = nop.m_numDsts;
  m_hasTypeParam = nop.m_hasTypeParam;
  m_dest         = nop.m_dest;
  m_extra        = nullptr;
}

void IRInstruction::become(IRUnit& unit, const IRInstruction* other) {
  assertx(other->isTransient() || m_numDsts == other->m_numDsts);
  auto& arena = unit.arena();

  if (hasEdges()) clearEdges();

  m_op = other->m_op;
  m_typeParam = other->m_typeParam;
  m_hasTypeParam = other->m_hasTypeParam;
  m_numSrcs = other->m_numSrcs;
  m_extra = other->m_extra ? cloneExtra(m_op, other->m_extra, arena) : nullptr;
  m_srcs = new (arena) SSATmp*[m_numSrcs];
  std::copy(other->m_srcs, other->m_srcs + m_numSrcs, m_srcs);

  if (hasEdges()) {
    assertx(other->hasEdges());  // m_op is from other now
    m_edges = new (arena) Edge[2];
    m_edges[0].setInst(this);
    m_edges[1].setInst(this);
    setNext(other->next());
    setTaken(other->taken());
  }
}

///////////////////////////////////////////////////////////////////////////////

enum MoveKind {
  Consume,
  MustMove,
  MayMove,
};

template<MoveKind move>
bool consumesRefImpl(const IRInstruction* inst, int srcNo) {
  if (!inst->consumesReferences()) {
    return false;
  }

  switch (inst->op()) {
    case ConcatStrStr:
    case ConcatStrInt:
    case ConcatStr3:
    case ConcatStr4:
      // Call a helper that decrefs the first argument
      return move == Consume && srcNo == 0;

    case StClosureArg:
    case StClosureCtx:
    case StContArValue:
    case StContArKey:
      return srcNo == 1;

    case Call:
    case CallUnpack:
      return move != MustMove && srcNo == 3;

    case InitCtx:
      return srcNo == 1;

    case AFWHBlockOn:
      // Consume the value being stored, not the thing it's being stored into
      return srcNo == 1;

    case ArraySet:
    case ArraySetRef:
    case VecSet:
    case VecSetRef:
    case DictSet:
    case DictSetRef:
    case AddNewElem:
    case AddNewElemKeyset:
    case AddNewElemVec:
      // Only consumes the reference to its input array
      return move == Consume && srcNo == 0;

    case AddElemStrKey:
    case AddElemIntKey:
    case DictAddElemStrKey:
    case DictAddElemIntKey:
      // Consumes the reference to its input array, and moves input value
      return srcNo != 0 || move == Consume;

    case LdSwitchStrIndex:
    case LdSwitchObjIndex:
      // consumes the switch input
      return move == Consume && srcNo == 0;

    case CreateAFWH:
    case CreateAFWHNoVV:
      return srcNo == 4;

    case CreateAGWH:
      return srcNo == 3;

    case CreateSSWH:
      return srcNo == 0;

    case InitPackedLayoutArray:
      return srcNo == 1;

    case InitPackedLayoutArrayLoop:
      return srcNo > 0;

    case NewPair:
    case NewColFromArray:
      return true;

    default:
      return move != MustMove;
  }
}

bool IRInstruction::consumesReference(int srcNo) const {
  return consumesRefImpl<Consume>(this, srcNo);
}

bool IRInstruction::movesReference(int srcNo) const {
  return consumesRefImpl<MustMove>(this, srcNo);
}

bool IRInstruction::mayMoveReference(int srcNo) const {
  return consumesRefImpl<MayMove>(this, srcNo);
}

///////////////////////////////////////////////////////////////////////////////

void IRInstruction::setOpcode(Opcode newOpc) {
  assertx(hasEdges() || !jit::hasEdges(newOpc)); // cannot allocate new edges
  if (hasEdges() && !jit::hasEdges(newOpc)) {
    clearEdges();
  }
  m_op = newOpc;
}

SSATmp* IRInstruction::dst(unsigned i) const {
  if (i == 0 && m_numDsts == 0) return nullptr;
  assertx(i < m_numDsts);
  assertx(naryDst() || i == 0);
  return hasDst() ? dst() : m_dsts[i];
}

///////////////////////////////////////////////////////////////////////////////

Type thisTypeFromFunc(const Func* func) {
  assertx(func && func->cls());
  // If the function is a cloned closure which may have a re-bound $this which
  // is not a subclass of the context return an unspecialized type.
  return func->hasForeignThis() ? TObj : Type::SubObj(func->cls());
}

///////////////////////////////////////////////////////////////////////////////
// outputType().

namespace {

Type unboxPtr(Type t) {
  assertx(t <= TPtrToGen || t <= TLvalToGen);
  auto const mcell = t & TMemToCell;
  auto const mref = t & TMemToBoxedInitCell;
  return mref.deref().inner().mem(t.memKind(), Ptr::Ref) | mcell;
}

Type boxPtr(Type t) {
  assertx(t <= TPtrToGen || t <= TLvalToGen);
  auto const rawBoxed = t.deref().unbox().box();
  auto const noNull = rawBoxed - TBoxedUninit;
  return noNull.mem(t.memKind(), t.ptrKind() - Ptr::Ref);
}

Type allocObjReturn(const IRInstruction* inst) {
  switch (inst->op()) {
    case ConstructClosure:
    case ConstructInstance:
      return Type::ExactObj(inst->extra<ClassData>()->cls);

    case NewInstanceRaw:
      return Type::ExactObj(inst->extra<NewInstanceRaw>()->cls);

    case AllocObj:
    case AllocObjReified:
      return inst->src(0)->hasConstVal()
        ? Type::ExactObj(inst->src(0)->clsVal())
        : TObj;

    case CreateGen:
      return Type::ExactObj(Generator::getClass());

    case CreateAGen:
      return Type::ExactObj(AsyncGenerator::getClass());

    case CreateAFWH:
    case CreateAFWHNoVV:
      return Type::ExactObj(c_AsyncFunctionWaitHandle::classof());

    case CreateAGWH:
      return Type::ExactObj(c_AsyncGeneratorWaitHandle::classof());

    case CreateAAWH:
      return Type::ExactObj(c_AwaitAllWaitHandle::classof());

    case CreateSSWH:
      return Type::ExactObj(c_StaticWaitHandle::classof());

    case FuncCred:
      return Type::ExactObj(FunctionCredential::classof());

    default:
      always_assert(false && "Invalid opcode returning AllocObj");
  }
}

Type arrElemReturn(const IRInstruction* inst) {
  assertx(inst->is(ArrayGet, MixedArrayGetK, ArrayIdx, LdPackedElem));
  assertx(inst->src(0)->isA(TArr));

  auto elem =
    arrElemType(inst->src(0)->type(), inst->src(1)->type(), inst->ctx());
  if (!elem.second) {
    if (inst->is(ArrayGet)) elem.first |= TInitNull;
    if (inst->is(ArrayIdx)) elem.first |= inst->src(2)->type();
  }
  if (inst->hasTypeParam()) elem.first &= inst->typeParam();
  return elem.first;
}

/*
* Analyze the type of return element (key or value) for different container.
*/
Type vecFirstLastReturn(const IRInstruction* inst, bool first) {
  assertx(inst->is(VecFirst, VecLast));
  assertx(inst->src(0)->isA(TVec | Type::Array(ArrayData::kPackedKind)));

  auto elem = vecFirstLastType(inst->src(0)->type(), first, inst->ctx());
  if (!elem.second) {
    elem.first |= TInitNull;
  }
  if (inst->hasTypeParam()) {
    elem.first &= inst->typeParam();
  }
  return elem.first;
}

Type dictFirstLastReturn(const IRInstruction* inst, bool first, bool isKey) {
  assertx(inst->is(DictFirst, DictLast, DictFirstKey, DictLastKey));
  assertx(inst->src(0)->isA(TDict | Type::Array(ArrayData::kMixedKind)));

  auto elem = dictFirstLastType(inst->src(0)->type(), isKey, first);
  if (!elem.second) {
    elem.first |= TInitNull;
  }
  if (inst->hasTypeParam()) {
    elem.first &= inst->typeParam();
  }
  return elem.first;
}

Type keysetFirstLastReturn(const IRInstruction* inst, bool first) {
  assertx(inst->is(KeysetFirst, KeysetLast));
  assertx(inst->src(0)->isA(TKeyset));

  auto elem = keysetFirstLastType(inst->src(0)->type(), first);
  if (!elem.second) {
    elem.first |= TInitNull;
  }
  if (inst->hasTypeParam()) {
    elem.first &= inst->typeParam();
  }
  return elem.first;
}

Type vecElemReturn(const IRInstruction* inst) {
  assertx(inst->is(LdVecElem));
  assertx(inst->src(0)->isA(TVec));
  assertx(inst->src(1)->isA(TInt));

  auto resultType =
    vecElemType(inst->src(0)->type(), inst->src(1)->type(), inst->ctx()).first;
  if (inst->hasTypeParam()) resultType &= inst->typeParam();
  return resultType;
}

Type dictElemReturn(const IRInstruction* inst) {
  assertx(inst->is(DictGet, DictGetK, DictGetQuiet, DictIdx));
  assertx(inst->src(0)->isA(TDict));
  assertx(inst->src(1)->isA(TInt | TStr));

  auto elem = dictElemType(inst->src(0)->type(), inst->src(1)->type());
  if (!elem.second) {
    if (inst->is(DictGetQuiet)) elem.first |= TInitNull;
    if (inst->is(DictIdx)) elem.first |= inst->src(2)->type();
  }
  if (inst->hasTypeParam()) elem.first &= inst->typeParam();
  return elem.first;
}

Type keysetElemReturn(const IRInstruction* inst) {
  assertx(inst->is(KeysetGet, KeysetGetK, KeysetGetQuiet, KeysetIdx));
  assertx(inst->src(0)->isA(TKeyset));
  assertx(inst->src(1)->isA(TInt | TStr));

  auto elem = keysetElemType(inst->src(0)->type(), inst->src(1)->type());
  if (!elem.second) {
    if (inst->is(KeysetGetQuiet)) elem.first |= TInitNull;
    if (inst->is(KeysetIdx)) elem.first |= inst->src(2)->type();
  }
  if (inst->hasTypeParam()) elem.first &= inst->typeParam();
  return elem.first;
}

Type ctxReturn(const IRInstruction* inst) {
  auto const func = inst->is(LdClosureCtx)
    ? inst->extra<LdClosureCtx>()->func : inst->func();
  if (!func) return TCtx;

  if (func->requiresThisInBody()) {
    return thisTypeFromFunc(func);
  }
  if (func->hasForeignThis()) {
    return func->isStatic() ? TCctx : TCtx;
  }
  if (inst->is(LdCctx) || func->isStatic()) {
    if (func->cls()->attrs() & AttrNoOverride) {
      return Type::cns(ConstCctx::cctx(func->cls()));
    }
    return TCctx;
  }
  return thisTypeFromFunc(func) | TCctx;
}

Type ctxClsReturn(const IRInstruction* inst) {
  // If we aren't loading the cls from the ctx of the current function doing
  // this makes no sense.
  if (!canonical(inst->src(0))->inst()->is(LdCtx, LdCctx)) return TCls;

  auto const func = inst->func();
  if (!func || func->hasForeignThis()) return TCls;
  return Type::SubCls(inst->ctx());
}

Type setElemReturn(const IRInstruction* inst) {
  assertx(inst->op() == SetElem);
  auto baseType = inst->src(minstrBaseIdx(inst->op()))->type().strip();

  // If the base is a Str, the result will always be a StaticStr (or
  // an exception). If the base might be a str, the result wil be
  // StaticStr or Nullptr. Otherwise, the result is always Nullptr.
  if (baseType <= TStr) {
    return TStaticStr;
  } else if (baseType.maybe(TStr)) {
    return TStaticStr | TNullptr;
  }
  return TNullptr;
}

Type newColReturn(const IRInstruction* inst) {
  assertx(inst->is(NewCol, NewPair, NewColFromArray));
  auto getColClassType = [&](CollectionType ct) -> Type {
    auto name = collections::typeToString(ct);
    auto cls = Unit::lookupUniqueClassInContext(name, inst->ctx());
    if (cls == nullptr) return TObj;
    return Type::ExactObj(cls);
  };

  if (inst->is(NewCol)) {
    return getColClassType(inst->extra<NewCol>()->type);
  } else if (inst->is(NewPair)) {
    return getColClassType(CollectionType::Pair);
  }
  return getColClassType(inst->extra<NewColFromArray>()->type);
}

Type builtinReturn(const IRInstruction* inst) {
  assertx(inst->is(CallBuiltin));
  return irgen::builtinReturnType(inst->extra<CallBuiltin>()->callee);
}

Type callReturn(const IRInstruction* inst) {
  assertx(inst->is(Call, CallUnpack));

  // Do not use the inferred Func* if we are forming a region. We may have
  // inferred the target of the call based on specialized type information
  // that won't be available when the region is translated. If we allow the
  // FCall to specialize using this information, we may infer narrower type
  // for the return value, erroneously preventing the region from breaking
  // on unknown type.

  if (inst->is(Call)) {
    // Async eager return needs to load TVAux
    if (inst->extra<Call>()->asyncEagerReturn) return TInitCell;
    if (inst->extra<Call>()->numOut) return TInitCell;
    if (inst->extra<Call>()->formingRegion) return TInitCell;
    return inst->src(2)->hasConstVal(TFunc)
      ? irgen::callReturnType(inst->src(2)->funcVal()) : TInitCell;
  }
  if (inst->is(CallUnpack)) {
    if (inst->extra<CallUnpack>()->numOut) return TInitCell;
    if (inst->extra<CallUnpack>()->formingRegion) return TInitCell;
    return inst->src(2)->hasConstVal(TFunc)
      ? irgen::callReturnType(inst->src(2)->funcVal()) : TInitCell;
  }
  not_reached();
}

Type genIterReturn(const IRInstruction* inst) {
  assertx(inst->is(ContEnter));
  return inst->extra<ContEnter>()->isAsync
    ? Type::SubObj(c_Awaitable::classof())
    : TInitNull;
}

// Integers get mapped to integer memo keys, everything else gets mapped to
// strings.
Type memoKeyReturn(const IRInstruction* inst) {
  assertx(inst->is(GetMemoKey, GetMemoKeyScalar));
  auto const srcType = inst->src(0)->type();
  if (srcType <= TInt) return TInt;
  if (!srcType.maybe(TInt)) return TStr;
  return TInt | TStr;
}

Type ptrToLvalReturn(const IRInstruction* inst) {
  auto const ptr = inst->src(0)->type();
  assertx(ptr <= TPtrToGen);
  return ptr.deref().mem(Mem::Lval, ptr.ptrKind());
}

template <uint32_t...> struct IdxSeq {};

inline Type unionReturn(const IRInstruction* /*inst*/, IdxSeq<>) {
  return TBottom;
}

template <uint32_t Idx, uint32_t... Rest>
inline Type unionReturn(const IRInstruction* inst, IdxSeq<Idx, Rest...>) {
  assertx(Idx < inst->numSrcs());
  return inst->src(Idx)->type() | unionReturn(inst, IdxSeq<Rest...>{});
}

} // namespace

Type outputType(const IRInstruction* inst, int /*dstId*/) {
  using namespace TypeNames;
  using TypeNames::TCA;
#define ND              assertx(0 && "outputType requires HasDest or NaryDest");
#define D(type)         return type;
#define DofS(n)         return inst->src(n)->type();
#define DRefineS(n)     return inst->src(n)->type() & inst->typeParam();
#define DParamMayRelax(t) return inst->typeParam();
#define DParam(t)       return inst->typeParam();
#define DLdObjCls {                                                \
  if (auto spec = inst->src(0)->type().clsSpec()) {                \
    auto const cls = spec.cls();                                   \
    return spec.exact() ? Type::ExactCls(cls) : Type::SubCls(cls); \
  }                                                                \
  return TCls;                                                     \
}
#define DUnboxPtr       return unboxPtr(inst->src(0)->type());
#define DBoxPtr         return boxPtr(inst->src(0)->type());
#define DAllocObj       return allocObjReturn(inst);
#define DArrElem        return arrElemReturn(inst);
#define DVecElem        return vecElemReturn(inst);
#define DDictElem       return dictElemReturn(inst);
#define DKeysetElem     return keysetElemReturn(inst);
// Get the type of first or last element for different array type
#define DVecFirstElem     return vecFirstLastReturn(inst, true);
#define DVecLastElem      return vecFirstLastReturn(inst, false);
#define DVecKey           return TInt | TInitNull;
#define DDictFirstElem    return dictFirstLastReturn(inst, true, false);
#define DDictLastElem     return dictFirstLastReturn(inst, false, false);
#define DDictFirstKey     return dictFirstLastReturn(inst, true, true);
#define DDictLastKey      return dictFirstLastReturn(inst, false, true);
#define DKeysetFirstElem  return keysetFirstLastReturn(inst, true);
#define DKeysetLastElem   return keysetFirstLastReturn(inst, false);
#define DArrPacked      return Type::Array(ArrayData::kPackedKind);
#define DArrMixed       return Type::Array(ArrayData::kMixedKind);
#define DArrRecord      return Type::Array(ArrayData::kRecordKind);
#define DVArr           return (RuntimeOption::EvalHackArrDVArrs \
                                ? TVec : Type::Array(ArrayData::kPackedKind));
#define DVArrOrNull     return ((RuntimeOption::EvalHackArrDVArrs             \
                                ? TVec : Type::Array(ArrayData::kPackedKind)) \
                               | TNullptr);
#define DDArr           return (RuntimeOption::EvalHackArrDVArrs \
                                ? TDict : Type::Array(ArrayData::kMixedKind));
#define DStaticDArr     return (RuntimeOption::EvalHackArrDVArrs \
                                ? TStaticDict \
                                : Type::StaticArray(ArrayData::kMixedKind));
#define DCol            return newColReturn(inst);
#define DCtx            return ctxReturn(inst);
#define DCtxCls         return ctxClsReturn(inst);
#define DMulti          return TBottom;
#define DSetElem        return setElemReturn(inst);
#define DBuiltin        return builtinReturn(inst);
#define DCall           return callReturn(inst);
#define DGenIter        return genIterReturn(inst);
#define DSubtract(n, t) return inst->src(n)->type() - t;
#define DCns            return TUninit | TInitNull | TBool | \
                               TInt | TDbl | TStr | TArr | \
                               TVec | TDict | TKeyset | TRes;
#define DUnion(...)     return unionReturn(inst, IdxSeq<__VA_ARGS__>{});
#define DMemoKey        return memoKeyReturn(inst);
#define DLvalOfPtr      return ptrToLvalReturn(inst);

#define O(name, dstinfo, srcinfo, flags) case name: dstinfo not_reached();

  switch (inst->op()) {
    IR_OPCODES
    default: not_reached();
  }

#undef O

#undef ND
#undef D
#undef DofS
#undef DRefineS
#undef DParamMayRelax
#undef DParam
#undef DLdObjCls
#undef DUnboxPtr
#undef DBoxPtr
#undef DAllocObj
#undef DArrElem
#undef DVecElem
#undef DDictElem
#undef DKeysetElem
#undef DVecFirstElem
#undef DVecLastElem
#undef DVecKey
#undef DDictFirstElem
#undef DDictLastElem
#undef DDictFirstKey
#undef DDictLastKey
#undef DKeysetFirstElem
#undef DKeysetLastElem
#undef DArrPacked
#undef DArrMixed
#undef DArrRecord
#undef DVArr
#undef DVArrOrNull
#undef DDArr
#undef DStaticDArr
#undef DCol
#undef DCtx
#undef DCtxCls
#undef DMulti
#undef DSetElem
#undef DBuiltin
#undef DCall
#undef DGenIter
#undef DSubtract
#undef DCns
#undef DUnion
#undef DMemoKey
#undef DLvalOfPtr
}

}}
