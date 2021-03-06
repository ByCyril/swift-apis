// Copyright 2020 The TensorFlow Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// An infinite sequence of collections of sample batches suitable for training
/// a DNN when samples are not uniformly sized.
///
/// - Parameter `Samples`: the type of collection from which samples will be
///   drawn.
/// - Parameter `Entropy`: a source of entropy used to randomize sample order in
///   each epoch.  See the `init` documentation for details.
///
/// The batches in each epoch:
/// - all have exactly the same number of samples.
/// - are formed from samples of similar size.
/// - start with a batch whose maximum sample size is the maximum size over all
///   samples used in the epoch.
public final class NonuniformTrainingEpochs<
  Samples: Collection,
  Entropy: RandomNumberGenerator
>: Sequence, IteratorProtocol {
  private let samples: Samples

  /// The number of samples in a batch.
  let batchSize: Int

  /// The ordering of samples in the current epoch.
  private var sampleOrder: [Samples.Index]

  /// The maximal number of sample batches whose samples will be sorted by size.
  private let batchesPerSort: Int

  /// A sorting predicate used to group samples of similar size.
  private let areInAscendingSizeOrder: (Samples.Element, Samples.Element) -> Bool

  // TODO: Figure out how to handle non-threasafe PRNGs with a parallel shuffle
  // algorithm.
  /// A source of entropy for shuffling samples.
  private var entropy: Entropy

  /// Creates an instance drawing samples from `samples` into batches of size
  /// `batchSize`.
  ///
  /// - Parameters:
  ///   - entropy: a source of randomness used to shuffle sample ordering. It
  ///     will be stored in `self`, so if it is only pseudorandom and has value
  ///     semantics, the sequence of epochs is determinstic and not dependent on
  ///     other operations.
  ///   - batchesPerSort: the number of batches across which to group sample
  ///     sizes similarly, or `nil` to indicate that the implementation should
  ///     choose a number. Choosing too high can destroy the effects of sample
  ///     shuffling in many training schemes, leading to poor results.  Choosing
  ///     too low will reduce the similarity of sizes in a given batch, leading
  ///     to inefficiency.
  ///   - areInAscendingSizeOrder: a predicate that returns `true` iff the size
  ///     of the first parameter is less than that of the second.
  public init(
    samples: Samples,
    batchSize: Int,
    entropy: Entropy,
    batchesPerSort: Int? = nil,
    areInAscendingSizeOrder:
      @escaping (Samples.Element, Samples.Element) -> Bool
  ) {
    self.samples = samples
    self.batchSize = batchSize
    sampleOrder = Array(samples.indices)
    let batchCount = sampleOrder.count / batchSize
    self.entropy = entropy
    self.batchesPerSort = batchesPerSort ?? Swift.max(2, batchCount / 100)
    self.areInAscendingSizeOrder = areInAscendingSizeOrder
  }

  /// The type of each epoch, a collection of batches of samples.
  public typealias Element = Slices<
    Sampling<Samples, Array<Samples.Index>.SubSequence>
  >

  /// Returns the next epoch in sequence.
  public func next() -> Element? {
    let remainder = sampleOrder.count % batchSize

    sampleOrder.withUnsafeMutableBufferPointer { order in
      // TODO: use a parallel shuffle like mergeshuffle
      // (http://ceur-ws.org/Vol-2113/paper3.pdf)
      order.shuffle(using: &entropy)

      // The indices of samples used in this epoch
      var epochSampleOrder = order.dropLast(remainder)

      // The index in order of the largest sample.
      let leader = epochSampleOrder.indices.max {
        areInAscendingSizeOrder(
          samples[epochSampleOrder[$0]], samples[epochSampleOrder[$1]])
      }!

      // The last position in epochSamples that will end up in the first batch.
      let lastOfFirstBatch = epochSampleOrder.index(atOffset: batchSize - 1)
      if leader > lastOfFirstBatch {
        epochSampleOrder[lastOfFirstBatch...leader]
          .rotate(shiftingToStart: leader)
      }

      // The regions of usedOrder to be sorted by descending batch size
      let megabatches =
        epochSampleOrder
        .inBatches(of: batchSize * batchesPerSort)

      for var megabatch in megabatches {
        // TODO: fully sorting is overkill; we should use introselect here.
        // Also, parallelize.
        megabatch.sort { areInAscendingSizeOrder(samples[$1], samples[$0]) }
      }
    }
    return samples.sampled(at: sampleOrder.dropLast(remainder))
      .inBatches(of: batchSize)
  }
}

extension NonuniformTrainingEpochs
where Entropy == SystemRandomNumberGenerator {
  /// Creates an instance drawing samples from `samples` into batches of size
  /// `batchSize`.
  ///
  /// - Parameters:
  ///   - batchesPerSort: the number of batches across which to group sample
  ///     sizes similarly, or `nil` to indicate that the implementation should
  ///     choose a number. Choosing too high can destroy the effects of sample
  ///     shuffling in many training schemes, leading to poor results.  Choosing
  ///     too low will reduce the similarity of sizes in a given batch, leading
  ///     to inefficiency.
  ///   - areInAscendingSizeOrder: a predicate that returns `true` iff the size
  ///     of the first parameter is less than that of the second.
  public convenience init(
    samples: Samples,
    batchSize: Int,
    batchesPerSort: Int? = nil,
    areInAscendingSizeOrder:
      @escaping (Samples.Element, Samples.Element) -> Bool
  ) {
    self.init(
      samples: samples,
      batchSize: batchSize,
      entropy: SystemRandomNumberGenerator(),
      batchesPerSort: batchesPerSort,
      areInAscendingSizeOrder: areInAscendingSizeOrder
    )
  }
}

/// Build batches for inference drawing samples from `samples` into batches of 
/// `batchSize`.
///
/// - Parameter areInAscendingSizeOrder: a predicate that      ...
///   - areInAscendingSizeOrder: a predicate that returns `true` iff the size
///     of the first parameter is less than that of the second.
///
/// Sorts `samples` without loading every sample in memory in a single array.
public func nonuniformInferenceBatches<Samples: Collection>(
  samples: Samples, batchSize: Int,
  areInAscendingSizeOrder:
    @escaping (Samples.Element, Samples.Element) -> Bool
) -> Slices<Sampling<Samples, [Samples.Index]>> {
  // The order of the samples.
  let sampleOrder = Array(samples.indices).sorted {
    areInAscendingSizeOrder(samples[$1], samples[$0])
  }
  return samples.sampled(at: sampleOrder).inBatches(of: batchSize)
}
