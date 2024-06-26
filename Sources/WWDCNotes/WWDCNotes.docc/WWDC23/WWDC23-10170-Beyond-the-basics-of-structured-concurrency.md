# Beyond the basics of structured concurrency

It’s all about the task tree: Find out how structured concurrency can help your apps manage automatic task cancellation, task priority propagation, and useful task-local value patterns. Learn how to manage resources in your app with useful patterns and the latest task group APIs. We’ll show you how you can leverage the power of the task tree and task-local values to gain insight into distributed systems.

@Metadata {
   @TitleHeading("WWDC23")
   @PageKind(sampleCode)
   @CallToAction(url: "https://developer.apple.com/wwdc23/10170", purpose: link, label: "Watch Video (24 min)")

   @Contributors {
      @GitHubUser(RamitSharma991)
   }
}



## Task hierarchy 
- unlocks automatic task cancellation, priority propagation, and useful task-local value behaviors.

### Concurrency in Swift

* Helps us to reason about concurrent code using well-defined points where execution branches off and runs concurrently.
* Automatically implements advanced behaviours. 
* Concurrent execution is triggered when you use an `async let`, a task group, create a task or detached task.
* Results rejoin the current execution at a suspension point, indicated by an `await`
* Structured tasks are created using `async let` and task groups.
* Unstructured tasks are created using `Task` and `Task.detached`
* Structured tasks live to the end of the scope where they are declared and are automatically cancelled when they go out.

***Example of making soup in a kitchen with Unstructured and structured concurrency***

### Unstructured concurrency 

Here we are creating unstructured Tasks to add concurrency to the functions, and awaiting their values when necessary.

```swift
func makeSoup(order: Order) async throws -> Soup {
    let boilingPot = Task { try await stove.boilBroth() }
    let choppedIngredients = Task { try await chopIngredients(order.ingredients) }
    let meat = Task { await marinate(meat: .chicken) }
    let soup = await Soup(meat: meat.value, ingredients: choppedIngredients.value)
    return await stove.cook(pot: boilingPot.value, soup: soup, duration: .minutes(10))
}
```

### Structured concurrency 

- Since we have a known number of child tasks to create, we can use the convenient `async let` syntax.
- These tasks form a structured relationship with their parent task. 

```swift
func makeSoup(order: Order) async throws -> Soup {
    async let pot = stove.boilBroth()
    async let choppedIngredients = chopIngredients(order.ingredients)
    async let meat = marinate(meat: .chicken)
    let soup = try await Soup(meat: meat, ingredients: choppedIngredients)
    return try await stove.cook(pot: pot, soup: soup, duration: .minutes(10))
}

```

## Task cancellation

- used to signal that the app no longer needs the result of a task and the task should stop and either return a partial result or throw an error.
- Structured tasks are cancelled implicitly when they go out of scope.
- call `cancelAll` on task groups to cancel all active children and any future child tasks.
- Unstructured tasks are cancelled explicitly with the `cancel` function.
- Cancelling the parent task results in the cancellation of all child tasks.
- Cancellation is cooperative, so child tasks aren't immediately stopped.

```swift
func makeSoup(order: Order) async throws -> Soup {
    async let pot = stove.boilBroth()

    guard !Task.isCancelled else {
        throw SoupCancellationError()
    }

    async let choppedIngredients = chopIngredients(order.ingredients)
    async let meat = marinate(meat: .chicken)
    let soup = try await Soup(meat: meat, ingredients: choppedIngredients)
    return try await stove.cook(pot: pot, soup: soup, duration: .minutes(10))
}
```

- If throwing a cancellation error instead of returning a partial result, we can call `Task.checkCancellation`, which throws a `CancellationError` if the task was cancelled.
- Cancellation checking is synchronous, so any function, asynchronous or synchronous, that should react to cancellation should check the task cancellation status before continuing. 
- *Polling* for cancellation with `isCancelled` or `checkCancellation` is useful when the task is running.
- `withTaskCancellationHandler` is useful at times when you may need to respond to cancellation while the task is suspended and no code is running.

### Cancellation and async sequences
- the asynchronous for-loop gets a new order before it is cancelled.

```swift
actor Cook {
    func handleShift<Orders>(orders: Orders) async throws
       where Orders: AsyncSequence,
             Orders.Element == Order {

        for try await order in orders {
            let soup = try await makeSoup(order)
            // ...
        }
    }
}
```
- the cancellation may take place while the task is suspended, waiting on the next order.
- use the cancellation handler to detect the cancellation event and break out of the asynchronous for-loop.
- These orders are produced from an `AsyncSequence`
- AsyncSequences are driven by an `AsyncIterator`, which defines an asynchronous `next` function.
- Like with synchronous iterators, the `next` function returns the next element in the sequence, or nil to indicate that we are at the end of the sequence.
- Many AsyncSequences are implemented with a state machine, which we use to stop the running sequence.

```swift
public func next() async -> Order? {
    return await withTaskCancellationHandler {
        let result = await kitchen.generateOrder()
        guard state.isRunning else {
            return nil
        }
        return result
    } onCancel: {
        state.cancel()
    }
}
```

### AsyncSequence state machine

- While actors are great for protecting encapsulated state they can’t really protect the protect the state machine.
- to modify and read individual properties on the state machine actors aren't quite the right tool.
- can't guarantee the order that operations run on an actor, so we can't ensure that our cancellation will run first.
- use `atomics` from the Swift Atomics package, a dispatch queue or locks instead.
- These mechanisms allow us to: 
    - synchronize the shared state
    - avoiding race conditions, while allowing us to cancel the running state machine without introducing an unstructured task in the cancellation handler.

```swift
private final class OrderState: Sendable {
    let protectedIsRunning = ManagedAtomic<Bool>(true)
    var isRunning: Bool {
        get { protectedIsRunning.load(ordering: .acquiring) }
        set { protectedIsRunning.store(newValue, ordering: .relaxed) }
    }
    func cancel() { isRunning = false }
}
```
- Therefore **Task cancellation**:
  - Propagate through the task tree.
  - Seamlessly integrates with throwing errors.
  - Event-driven cancellation handlers or explicit polling.


## Task priority 

- Priority is your way to communicate to the system how urgent a given task is.
- Certain tasks, like responding to a button press, need to run immediately or the app will appear frozen.
- Meanwhile, other tasks, like prefetching content from a server, can run in the background without anyone noticing.
- A *priority inversion* happens when a high-priority task is waiting on the result of a lower-priority task.
- By default, child tasks inherit their priority from their parent.
- If the parent is running in a task at medium priority, all child tasks will also run at medium priority.

### Structured priority escalation

- Lower priority tasks escalate priority when awaited on by a higher priority task.
- Escalation propagates through the task tree.
- Priority remains escalated until the task completes.
- It's not possible to undo a priority escalation.


## Task group patterns

A powerful tool used for limiting and managing concurrency.

Example to see the pattern more clearly: 

```swift
    withTaskGroup(of: Something.self) { group in
    for _ in 0..<maxConcurrentTasks {
        group.addTask { }
    }
    while let <partial result> = await group.next() {
        if !shouldStop { 
            group.addTask { }
        }
    }
}
```

- The initial loop creates up to the maximum number of concurrent tasks, ensuring that we don't create too many.
- Once the maximum number of tasks is running, we wait for one to finish.
- After it finishes and we haven't hit a stopping condition, we create a new task to keep making progress.
- This limits the number of concurrent tasks in the group since we won't start new work until earlier tasks finish.


### Discarding task groups

- `withDiscardingTaskGroup` API is New Swift 5.9  
- Discarding task groups don't hold onto the results of completed child tasks.
- Resources used by tasks are freed immediately after the task finishes.

```swift
	withDiscardingTaskGroup { group in
		group.addTask()
	}
	
	withThrowingDiscardingTaskGroup { group in 
		group.addTask()
	}
```

- We can change the run method to make use of a discarding task group.
- Discarding task groups automatically clean up their children, so there is no need to explicitly cancel the group and clean up.
- The discarding task group also has automatic sibling cancellation.
- If any of the child tasks throw an error, all remaining tasks are automatically cancelled.


```swift
func run() async throws {
    try await withThrowingDiscardingTaskGroup { group in
        for cook in staff.keys {
            group.addTask { try await cook.handleShift() }
        }

        group.addTask { // keep the restaurant going until closing time
            try await Task.sleep(for: shiftDuration)
            throw TimeToCloseError()
        }
    }
}
```

### TaskGroups 

- `DiscardingTaskGroup` releases resources immediately on task completion .
- Use the completion of one task to signal the creation of the next in a TaskGroup.

## Task-local values

- A task-local value is a piece of data associated with a given task, or more precisely, a task hierarchy. 
- It's like a global variable, but the value bound to the task-local value is only available from the current task hierarchy.
- Task-local values are declared as static properties with the `TaskLocal` property wrapper.
- It's a good practice to make the task local optional.

```swift
  @TaskLocal static var orderID: Int?
  @TaskLocal static var cook: String?
```

- Any task that doesn't have the value set will need to return a default value, which is easily represented by a nil optional.
- An unbound task local contains its default value.

```swift
//TaskLocal Values
actor Kitchen {
    @TaskLocal static var orderID: Int?
    @TaskLocal static var cook: String?
    func logStatus() {
        print("Current cook: \(Kitchen.cook ?? "none")")
    }
}

let kitchen = Kitchen()
await kitchen.logStatus()
await Kitchen.$cook.withValue("Sakura") {
    await kitchen.logStatus()
}
await kitchen.logStatus()
```

- Task-local values can't be assigned to explicitly, but must be bound for a specific scope. 
- The binding lasts for the duration of the scope, and reverts back to the original value at the end of the scope.

###  Swift log
- Logging by hand is repetitive and verbose, which leads to subtle bugs and typos. To prevent that we use SwiftLog.
- SwiftLog is a logging API package with multiple backing implementations.
- Allows us to drop in a logging back end that suites your needs without making changes to your server.
- MetadataProvider `Logger.MetadataProvider` is a new API in SwiftLog 1.5 that: 
    - Automatically includes information in Logger.Metadata
    - Good contextual information makes good logs.
    - uses a dictionary-like structure, mapping a name to the value being logged. 
    - Multiple libraries may define their own metadata provider to look for library-specific information.
    - defines a `multiplex` function, which takes multiple metadata providers and combines them into a single object.

```swift
//MetaDataProvider in action
let orderMetadataProvider = Logger.MetadataProvider {
    var metadata: Logger.Metadata = [:]
    if let orderID = Kitchen.orderID {
        metadata["orderID"] = "\(orderID)"
    }
    return metadata
}

let chefMetadataProvider = Logger.MetadataProvider {
    var metadata: Logger.Metadata = [:]
    if let chef = Kitchen.chef {
        metadata["chef"] = "\(chef)"
    }
    return metadata
}
```

- Once we have a metadata provider, we initialize the logging system with that provider, and we're ready to start logging.

```swift
let metadataProvider = Logger.MetadataProvider.multiplex([orderMetadataProvider,
                                                          chefMetadataProvider])

LoggingSystem.bootstrap(StreamLogHandler.standardOutput, metadataProvider: metadataProvider)

let logger = Logger(label: "KitchenService")
```

- The logs automatically include information specified in the metadata provider, so we don't need to worry about including it in the log message.

```swift
//Logging and metadata provider
func makeSoup(order: Order) async throws -> Soup {
    logger.info("Preparing soup order")
    async let pot = stove.boilBroth()
    async let choppedIngredients = chopIngredients(order.ingredients)
    async let meat = marinate(meat: .chicken)
    let soup = try await Soup(meat: meat, ingredients: choppedIngredients)
    return try await stove.cook(pot: pot, soup: soup, duration: .minutes(10))
}
```

Task-local values:
- Attach metadata to the current task
- Inherited y child as well as Task { }
- Low-level building block for context


### Task traces
To trace and profile a concurrent distributed system

#### Swift Distributed Tracing 

- Open source package for server ecosystem.
- Provides an extensible instrumentation API.
- Allows us to leverage the benefits of the task tree across multiple systems to gain insight into performance characteristics and task relationships. 
- Similar to swift Log and Swift Metrics.
- The Swift Distributed Tracing package has an implementation of the `OpenTelemetry` protocol, so existing tracing solutions, like Zipkin and Jaeger, will work out of the box.
- fills in the opaque `waiting for response` in Xcode Instruments with detailed information about what is happening in the server.
- a little different from tracing processes locally.
- Instead of getting a trace per-function, we instrument our code with spans using the `withSpan` API.

```swift
//Profile server-side execution
func makeSoup(order: Order) async throws -> Soup {
    try await withSpan("makeSoup(\(order.id)") { span in
        async let pot = stove.boilWater()
        async let choppedIngredients = chopIngredients(order.ingredients)
        async let meat = marinate(meat: .chicken)
        let soup = try await Soup(meat: meat, ingredients: choppedIngredients)
        return try await stove.cook(pot: pot, soup: soup, duration: .minutes(10))
    }
}
```

- Spans allow us to assign names to regions of code that are reported in the tracing system.
- Spans don't need to cover an entire function.
- They can provide more insight on specific pieces of a given function.
- `withSpan` annotates our tasks with additional trace IDs and other metadata, allowing the tracing system to merge the task trees into a single trace.
- The tracing system has enough information to provide you with insight into the task hierarchy, along with information about the runtime performance characteristics of a task.
- The span name is presented in the tracing UI.
- You'll want to keep them short and descriptive so that you can easily find information about a specific span without clutter.
- We can attach additional metadata with the use of span attributes

```swift
func makeSoup(order: Order) async throws -> Soup {
    try await withSpan(#function) { span in
        span.attributes["kitchen.order.id"] = order.id
        async let pot = stove.boilWater()
        async let choppedIngredients = chopIngredients(order.ingredients)
        async let meat = marinate(meat: .chicken)
        let soup = try await Soup(meat: meat, ingredients: choppedIngredients)
        return try await stove.cook(pot: pot, soup: soup, duration: .minutes(10))
    }
}
```
- Here we've replaced the span name with the `#function` directive to automatically fill the span name with the function name
- used the span attribute to attach the current order ID to the span information reported to the tracer.

### Trace attributes

* Tracing systems usually present the attributes while inspecting a given span.
* Most spans come with HTTP status codes, request and response sizes, start and end times, and other metadata making it easy to track information passing through the system.
* If a task fails and throws an error, that information is also presented in the span and reported in the tracing system.
* Since spans contain both timing information and the relationships of tasks in the tree, it's a helpful way to track down errors caused by timing races and identify how they impact other tasks.

### The distributed of distributed tracing (Visualize traces even across multiple services/nodes)

* Distributed tracing is most powerful when all parts of the system embrace traces, including the HTTP clients, servers, and other RPC systems.
* `Swift Distributed Tracing` leverages task-local values, built on the task trees, to automatically propagate all of the information necessary to produce reliable cross-node traces.
* Structured tasks:
  * unlock the secrets of concurrent systems.
  * provide tools to automatically cancel operations.
  * automatically propagate priority information.
  * facilitate tracing complex distributed workloads.
