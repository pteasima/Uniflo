import Foundation
import Combine

public struct SubscriptionEffect<Action, Environment>: Equatable {
    let perform: (Environment) -> AnyPublisher<Action, Never>
    private let data: (keyPath: AnyKeyPath, input: Any, transform: AnyKeyPath)
    private let eq: (SubscriptionEffect) -> Bool
    public init<Input: Equatable, Output, P: Publisher>(_ keyPath: KeyPath<Environment, (Input) -> P>, _ input: Input, _ transform: KeyPath<Output, Action>) where P.Output == Output, P.Failure == Never {
        perform = { effects in
            effects[keyPath: keyPath](input).map { $0[keyPath: transform] }.eraseToAnyPublisher()
        }
        data = (keyPath, input, transform)
        eq = { other in keyPath == other.data.keyPath && input == other.data.input as? Input && transform == other.data.transform }
    }
    public init<Output, P: Publisher>(_ keyPath: KeyPath<Environment, () -> P>, _ transform: KeyPath<Output, Action>) where P.Output == Output, P.Failure == Never {
        perform = { effects in
            effects[keyPath: keyPath]().map { $0[keyPath: transform] }.eraseToAnyPublisher()
        }
        data = (keyPath, (), transform)
        eq = { other in keyPath == other.data.keyPath && transform == other.data.transform }
    }
    
    public static func ==(lhs: SubscriptionEffect, rhs: SubscriptionEffect) -> Bool {
        lhs.eq(rhs)
    }
}

// above we use `transform` to produce Action from Output. But if Action is EmptyInitilizable, we can create the action ourselves, and `inject` the value into it.
// if action accepts Output as its only parameter (most of the time), we can use Action's enum properties (no need to extend Output with a var)
public extension SubscriptionEffect where Action: EmptyInitializable {
  init<Input: Equatable, Output, P: Publisher>(_ keyPath: KeyPath<Environment, (Input) -> P>, _ input: Input, _ inject: WritableKeyPath<Action, Output?>) where P.Output == Output, P.Failure == Never {
      perform = { effects in
          effects[keyPath: keyPath](input).map {
            var action = Action()
            action[keyPath: inject] = $0
            return action
          }.eraseToAnyPublisher()
      }
      data = (keyPath, input, inject)
      eq = { other in keyPath == other.data.keyPath && input == other.data.input as? Input && inject == other.data.transform }
  }
  init<Output, P: Publisher>(_ keyPath: KeyPath<Environment, () -> P>, _ inject: WritableKeyPath<Action, Output?>) where P.Output == Output, P.Failure == Never {
      perform = { effects in
          effects[keyPath: keyPath]().map {
            var action = Action()
            action[keyPath: inject] = $0
            return action
          }.eraseToAnyPublisher()
      }
      data = (keyPath, (), inject)
      eq = { other in keyPath == other.data.keyPath && inject == other.data.transform }
  }
}
