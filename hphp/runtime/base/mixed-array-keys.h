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

#ifndef incl_HPHP_MIXED_ARRAY_KEYS_H_
#define incl_HPHP_MIXED_ARRAY_KEYS_H_

#include "hphp/runtime/base/array-data.h"
#include "hphp/runtime/base/string-data.h"

namespace HPHP {

// Forward declaration needed for checkInvariants.
struct MixedArray;

/*
 * We use four bits in the MixedArray header to track a bit-set that tells us
 * if the MixedArray contains certain types of keys. In particular, we track
 * int keys, static str keys, non-static str keys, and tombstones.
 *
 * Whenever we add a key to a MixedArray, we set a bit in this bit-set. Doing
 * so means that the bit-set is conservative: if a key is in the array, then
 * the corresponding bit will be set. However, we may have bits in the bitset
 * that correspond to keys that aren't present - for example, if we add an int
 * key to the array and then remove it, we'll leave the bit set.
 *
 * Despite this conservative behavior, this bitset can be quite useful for
 * optimizations, because we don't often remove keys from arrays. For example,
 * if the bit for non-static str keys is unset, we can skip releasing keys.
 */
struct MixedArrayKeys {
  /*
   * Equality operator (used in assertions).
   */
  bool operator==(MixedArrayKeys other) const {
    return m_bits == other.m_bits;
  }

  /*
   * A variety of getters for the key-types bitset. Because of our conservative
   * tracking, "may have" functions may return false positive, and "must have"
   * functions may return false negatives; callers must handle this fact.
   */
  bool mayIncludeCounted() const {
    return (m_bits & kNonStaticStrKey) != 0;
  }
  bool mayIncludeTombstone() const {
    return (m_bits & kTombstoneKey) != 0;
  }
  bool mustBeStaticStrs() const {
    return (m_bits & ~kStaticStrKey) == 0;
  }

  /*
   * In one comparison we check both the kind and the fact that arr only
   * has static string keys (no tombstones, int keys, or counted str keys).
   * As above, this method may return false negatives.
   */
  static bool isMixedWithStaticStrKeys(const ArrayData* arr) {
    auto const test = static_cast<uint32_t>(HeaderKind::Mixed);
    auto const mask = static_cast<uint32_t>(~kStaticStrKey) << 24 |
                      static_cast<uint32_t>(0xff);
    return (*(reinterpret_cast<const uint32_t*>(arr) + 1) & mask) == test;
  }

  /*
   * Call these methods to get key types in m_aux format. We initialize m_aux
   * in a single store when we write a header, so we can't use the APIs below.
   */
  uint16_t packForAux() {
    return m_bits << 8;
  }
  static uint16_t packIntsForAux() {
    return kIntKey << 8;
  }
  static uint16_t packStaticStrsForAux() {
    return kTrackStaticStrKeys ? (kStaticStrKey << 8) : 0;
  }
  static uint16_t compactPacked(uint16_t aux) {
    return aux & ~(static_cast<uint16_t>(kTombstoneKey) << 8);
  }

  /*
   * Call these methods when performing the appropriate bulk operation.
   */
  void copyFrom(MixedArrayKeys other, bool compact) {
    m_bits |= other.m_bits & (compact ? ~kTombstoneKey : 0xff);
  }
  void makeCompact() {
    m_bits &= ~kTombstoneKey;
  }
  void makeUncounted() {
    if (kTrackStaticStrKeys && (m_bits & kNonStaticStrKey)) {
      m_bits = (m_bits & ~kNonStaticStrKey) | kStaticStrKey;
    } else {
      m_bits &= ~kNonStaticStrKey;
    }
  }
  void renumberKeys() {
    m_bits = kIntKey;
  }

  /*
   * Call these methods when inserting a new key into the array.
   */
  void recordInt() {
    m_bits |= kIntKey;
  }
  void recordStr(const StringData* sd) {
    if (kTrackStaticStrKeys) {
      m_bits |= sd->isStatic() ? kStaticStrKey : kNonStaticStrKey;
    } else {
      if (!sd->isStatic()) m_bits |= kNonStaticStrKey;
    }
  }
  void recordTombstone() {
    m_bits |= kTombstoneKey;
  }

  /*
   * Check that m_bits is a valid key types bitset for the given MixedArray.
   * This check is very slow - it requires a full traversal of the array.
   */
  bool checkInvariants(const MixedArray* ad) const;

private:
  // To save on stores, we can avoid tracking static string keys.
  //
  // We'll probably get rid of this option as soon as we have a use for
  // checking that all keys are, say, ints - not tracking static keys would
  // prevent us from doing that check soundly.
  static constexpr bool kTrackStaticStrKeys = false;

  static constexpr uint8_t kNonStaticStrKey = 0b0001;
  static constexpr uint8_t kStaticStrKey    = 0b0010;
  static constexpr uint8_t kIntKey          = 0b0100;
  static constexpr uint8_t kTombstoneKey    = 0b1000;

  uint8_t m_bits;
};

} // namespace HPHP

#endif // incl_HPHP_MIXED_ARRAY_KEYS_H_
