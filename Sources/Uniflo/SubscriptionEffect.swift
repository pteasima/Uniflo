import Foundation
import Combine

public struct SubscriptionEffect<Action, Environment>: Equatable {
    let perform: (Environment) -> AnyPublisher<Action, Never>
    private let data: (keyPath: AnyKeyPath, input: Any, transform: AnyKeyPath)
    private let eq: (SubscriptionEffect) -> Bool
    public init<Input: Equatable, Output, P: Publisher>(_ publisherKeyPath: KeyPath<Environment, (Input) -> P>, _ input: Input, _ transform: KeyPath<Output, Action>) where P.Output == Output, P.Failure == Never {
        perform = { environment in
            environment[keyPath: publisherKeyPath](input).map { $0[keyPath: transform] }.eraseToAnyPublisher()
        }
        data = (publisherKeyPath, input, transform)
        eq = { other in publisherKeyPath == other.data.keyPath && input == other.data.input as? Input && transform == other.data.transform }
    }
    public init<Output, P: Publisher>(_ publisherKeyPath: KeyPath<Environment, () -> P>, _ transform: KeyPath<Output, Action>) where P.Output == Output, P.Failure == Never {
        perform = { environment in
            environment[keyPath: publisherKeyPath]().map { $0[keyPath: transform] }.eraseToAnyPublisher()
        }
        data = (publisherKeyPath, (), transform)
        eq = { other in publisherKeyPath == other.data.keyPath && transform == other.data.transform }
    }
    
    public static func ==(lhs: SubscriptionEffect, rhs: SubscriptionEffect) -> Bool {
        lhs.eq(rhs)
    }
}

// above we use `transform` to produce Action from Output. But if Action is EmptyInitilizable, we can create the action ourselves, and `inject` the value into it.
// if action accepts Output as its only parameter (most of the time), we can use Action's enum properties (no need to extend Output with a var)
public extension SubscriptionEffect where Action: EmptyInitializable {
  init<Input: Equatable, Output, P: Publisher>(_ publisherKeyPath: KeyPath<Environment, (Input) -> P>, _ input: Input, _ inject: WritableKeyPath<Action, Output?>) where P.Output == Output, P.Failure == Never {
      perform = { environment in
          environment[keyPath: publisherKeyPath](input).map {
            var action = Action()
            action[keyPath: inject] = $0
            return action
          }.eraseToAnyPublisher()
      }
      data = (publisherKeyPath, input, inject)
      eq = { other in publisherKeyPath == other.data.keyPath && input == other.data.input as? Input && inject == other.data.transform }
  }
  init<Output, P: Publisher>(_ publisherKeyPath: KeyPath<Environment, () -> P>, _ inject: WritableKeyPath<Action, Output?>) where P.Output == Output, P.Failure == Never {
      perform = { environment in
          environment[keyPath: publisherKeyPath]().map {
            var action = Action()
            action[keyPath: inject] = $0
            return action
          }.eraseToAnyPublisher()
      }
      data = (publisherKeyPath, (), inject)
      eq = { other in publisherKeyPath == other.data.keyPath && inject == other.data.transform }
  }
}

// MARK: Retrying subscriptions

public extension SubscriptionEffect {
  init<Input: Equatable, Output, Failure, P: Publisher>(retrying publisherKeyPath: KeyPath<Environment, (Input) -> P>, _ input: Input, _ transform: KeyPath<Result<Output, Failure>, Action>) where P.Output == Output, P.Failure == Failure {
      perform = { environment in
        func failablePerform() -> AnyPublisher<Result<Output, Failure>, Never> {
          environment[keyPath: publisherKeyPath](input)
            .map(Result.success)
            .catch { error in
              failablePerform()
                .prepend(.failure(error))
          }
          .eraseToAnyPublisher()
        }
        return failablePerform()
          .map { $0[keyPath: transform] }
          .eraseToAnyPublisher()
      }
      data = (publisherKeyPath, input, transform)
      eq = { other in publisherKeyPath == other.data.keyPath && input == other.data.input as? Input && transform == other.data.transform }
  }
  init<Output, Failure, P: Publisher>(retrying publisherKeyPath: KeyPath<Environment, () -> P>, _ transform: KeyPath<Result<Output, Failure>, Action>) where P.Output == Output, P.Failure == Failure {
      perform = { environment in
        func failablePerform() -> AnyPublisher<Result<Output, Failure>, Never> {
          environment[keyPath: publisherKeyPath]()
            .map(Result.success)
            .catch { error in
              failablePerform()
                .prepend(.failure(error))
          }
          .eraseToAnyPublisher()
        }
        return failablePerform()
          .map { $0[keyPath: transform] }
          .eraseToAnyPublisher()
      }
      data = (publisherKeyPath, (), transform)
      eq = { other in publisherKeyPath == other.data.keyPath && transform == other.data.transform }
  }
}

public extension SubscriptionEffect where Action: EmptyInitializable {
  init<Input: Equatable, Output, Failure, P: Publisher>(retrying publisherKeyPath: KeyPath<Environment, (Input) -> P>, _ input: Input, _ inject: WritableKeyPath<Action, Result<Output, Failure>?>) where P.Output == Output, P.Failure == Failure {
      perform = { environment in
        func failablePerform() -> AnyPublisher<Result<Output, Failure>, Never> {
          environment[keyPath: publisherKeyPath](input)
            .map(Result.success)
            .catch { error in
              failablePerform()
                .delay(for: 1, scheduler: DispatchQueue.main)
                .prepend(.failure(error))
          }
          .eraseToAnyPublisher()
        }
        return failablePerform()
          .map {
            var action = Action()
            action[keyPath: inject] = $0
            return action
        }
          .eraseToAnyPublisher()
      }
      data = (publisherKeyPath, input, inject)
      eq = { other in publisherKeyPath == other.data.keyPath && input == other.data.input as? Input && inject == other.data.transform }
  }
  init<Output, Failure, P: Publisher>(retrying publisherKeyPath: KeyPath<Environment, () -> P>, _ inject: WritableKeyPath<Action, Result<Output, Failure>?>) where P.Output == Output, P.Failure == Failure {
      perform = { environment in
        func failablePerform() -> AnyPublisher<Result<Output, Failure>, Never> {
          environment[keyPath: publisherKeyPath]()
            .map(Result.success)
            .catch { error -> Publishers.HandleEvents<Publishers.Concatenate<Publishers.Sequence<[Result<Output, Failure>], Never>, Deferred<AnyPublisher<Result<Output, Failure>, Never>>>> in
              //this is a workaround for https://twitter.com/pteasima/status/1163453601324392453?s=20, where the prepend eats up the cancelled event
              var isCancelled = false
              return Deferred { isCancelled ? Empty<Result<Output, Failure>, Never>(completeImmediately: true).eraseToAnyPublisher() : failablePerform() }
//              .print("what now?")
              .prepend(.failure(error))
              .handleEvents(receiveCancel: {
                isCancelled = true
              })
          }
          .eraseToAnyPublisher()
        }
        return failablePerform()
          .map {
              var action = Action()
              action[keyPath: inject] = $0
              return action
          }
          .eraseToAnyPublisher()
      }
      data = (publisherKeyPath, (), inject)
      eq = { other in publisherKeyPath == other.data.keyPath && inject == other.data.transform }
  }
}
