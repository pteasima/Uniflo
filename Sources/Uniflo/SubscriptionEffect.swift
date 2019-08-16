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
    
    public static func ==(lhs: SubscriptionEffect, rhs: SubscriptionEffect) -> Bool {
        lhs.eq(rhs)
    }
}

