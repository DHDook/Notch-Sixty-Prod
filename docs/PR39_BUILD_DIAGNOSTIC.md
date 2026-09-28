# PR39 build diagnostic

```text

SwiftEmitModule normal arm64 Emitting\ module\ for\ NotchSixty (in target 'NotchSixty' from project 'NotchSixty')
/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:319:16: error: covariant 'Self' type cannot be referenced from a stored property initializer
317 |     private var drainBuffer = [N60AnalysisFrame](
318 |         repeating: N60AnalysisFrame(inputLeft: 0, inputRight: 0, outputLeft: 0, outputRight: 0),
319 |         count: Self.drainCapacity
    |                `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
318 |         repeating: N60AnalysisFrame(inputLeft: 0, inputRight: 0, outputLeft: 0, outputRight: 0),
319 |         count: Self.drainCapacity
    |                `- error: covariant 'Self' type cannot be referenced from a stored property initializer
320 |     )
321 |     private var inputHistory = [Float](repeating: 0, count: Self.historyCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:321:61: error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
321 |     private var inputHistory = [Float](repeating: 0, count: Self.historyCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:321:61: error: covariant 'Self' type cannot be referenced from a stored property initializer
319 |         count: Self.drainCapacity
320 |     )
321 |     private var inputHistory = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                             `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
320 |     )
321 |     private var inputHistory = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                             `- error: covariant 'Self' type cannot be referenced from a stored property initializer
322 |     private var outputHistory = [Float](repeating: 0, count: Self.historyCapacity)
323 |     private var outputLeftHistory = [Float](repeating: 0, count: Self.historyCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:322:62: error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
323 |     private var outputLeftHistory = [Float](repeating: 0, count: Self.historyCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:322:62: error: covariant 'Self' type cannot be referenced from a stored property initializer
320 |     )
321 |     private var inputHistory = [Float](repeating: 0, count: Self.historyCapacity)
322 |     private var outputHistory = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                              `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
321 |     private var inputHistory = [Float](repeating: 0, count: Self.historyCapacity)
322 |     private var outputHistory = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                              `- error: covariant 'Self' type cannot be referenced from a stored property initializer
323 |     private var outputLeftHistory = [Float](repeating: 0, count: Self.historyCapacity)
324 |     private var outputRightHistory = [Float](repeating: 0, count: Self.historyCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:323:66: error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
324 |     private var outputRightHistory = [Float](repeating: 0, count: Self.historyCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:323:66: error: covariant 'Self' type cannot be referenced from a stored property initializer
321 |     private var inputHistory = [Float](repeating: 0, count: Self.historyCapacity)
322 |     private var outputHistory = [Float](repeating: 0, count: Self.historyCapacity)
323 |     private var outputLeftHistory = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                                  `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
322 |     private var outputHistory = [Float](repeating: 0, count: Self.historyCapacity)
323 |     private var outputLeftHistory = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                                  `- error: covariant 'Self' type cannot be referenced from a stored property initializer
324 |     private var outputRightHistory = [Float](repeating: 0, count: Self.historyCapacity)
325 |     private var historyWriteIndex = 0

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:324:67: error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
325 |     private var historyWriteIndex = 0

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:324:67: error: covariant 'Self' type cannot be referenced from a stored property initializer
322 |     private var outputHistory = [Float](repeating: 0, count: Self.historyCapacity)
323 |     private var outputLeftHistory = [Float](repeating: 0, count: Self.historyCapacity)
324 |     private var outputRightHistory = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                                   `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
323 |     private var outputLeftHistory = [Float](repeating: 0, count: Self.historyCapacity)
324 |     private var outputRightHistory = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                                   `- error: covariant 'Self' type cannot be referenced from a stored property initializer
325 |     private var historyWriteIndex = 0
326 |     private var historyCount = 0

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:328:60: error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
326 |     private var historyCount = 0

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:328:60: error: covariant 'Self' type cannot be referenced from a stored property initializer
326 |     private var historyCount = 0
327 | 
328 |     private var latestInput = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                            `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
327 | 
328 |     private var latestInput = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                            `- error: covariant 'Self' type cannot be referenced from a stored property initializer
329 |     private var latestOutput = [Float](repeating: 0, count: Self.historyCapacity)
330 |     private var latestLeft = [Float](repeating: 0, count: Self.correlationCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:329:61: error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
330 |     private var latestLeft = [Float](repeating: 0, count: Self.correlationCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:329:61: error: covariant 'Self' type cannot be referenced from a stored property initializer
327 | 
328 |     private var latestInput = [Float](repeating: 0, count: Self.historyCapacity)
329 |     private var latestOutput = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                             `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
328 |     private var latestInput = [Float](repeating: 0, count: Self.historyCapacity)
329 |     private var latestOutput = [Float](repeating: 0, count: Self.historyCapacity)
    |                                                             `- error: covariant 'Self' type cannot be referenced from a stored property initializer
330 |     private var latestLeft = [Float](repeating: 0, count: Self.correlationCapacity)
331 |     private var latestRight = [Float](repeating: 0, count: Self.correlationCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:330:59: error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
331 |     private var latestRight = [Float](repeating: 0, count: Self.correlationCapacity)

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:330:59: error: covariant 'Self' type cannot be referenced from a stored property initializer
328 |     private var latestInput = [Float](repeating: 0, count: Self.historyCapacity)
329 |     private var latestOutput = [Float](repeating: 0, count: Self.historyCapacity)
330 |     private var latestLeft = [Float](repeating: 0, count: Self.correlationCapacity)
    |                                                           `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
329 |     private var latestOutput = [Float](repeating: 0, count: Self.historyCapacity)
330 |     private var latestLeft = [Float](repeating: 0, count: Self.correlationCapacity)
    |                                                           `- error: covariant 'Self' type cannot be referenced from a stored property initializer
331 |     private var latestRight = [Float](repeating: 0, count: Self.correlationCapacity)
332 | 

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:331:60: error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
332 | 

/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:331:60: error: covariant 'Self' type cannot be referenced from a stored property initializer
329 |     private var latestOutput = [Float](repeating: 0, count: Self.historyCapacity)
330 |     private var latestLeft = [Float](repeating: 0, count: Self.correlationCapacity)
331 |     private var latestRight = [Float](repeating: 0, count: Self.correlationCapacity)
    |                                                            `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
330 |     private var latestLeft = [Float](repeating: 0, count: Self.correlationCapacity)
331 |     private var latestRight = [Float](repeating: 0, count: Self.correlationCapacity)
    |                                                            `- error: covariant 'Self' type cannot be referenced from a stored property initializer
332 | 
333 |     private let spectrumAnalyzer = ProductionSpectrumAnalyzer()
Failed frontend command:

```

```text

SwiftCompile normal arm64 Compiling\ AudioDiagnosticsSnapshot.swift,\ ProductionAnalysisWorker.swift,\ StereoPlaybackControl.swift,\ DynamicsConfiguration.swift,\ MasterVolumeDeviceController.swift,\ GeneratedAssetSymbols.swift /Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift /Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift /Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Audio/StereoPlaybackControl.swift /Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Audio/DynamicsConfiguration.swift /Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Audio/CoreAudio/MasterVolumeDeviceController.swift /Users/runner/Library/Developer/Xcode/DerivedData/NotchSixty-ggjxdobswfqdrpaphpnrjydcooof/Build/Intermediates.noindex/NotchSixty.build/Debug/NotchSixty.build/DerivedSources/GeneratedAssetSymbols.swift (in target 'NotchSixty' from project 'NotchSixty')
/Users/runner/work/Notch-Sixty-Prod/Notch-Sixty-Prod/NotchSixty/Diagnostics/ProductionAnalysisWorker.swift:319:16: error: covariant 'Self' type cannot be referenced from a stored property initializer
317 |     private var drainBuffer = [N60AnalysisFrame](
318 |         repeating: N60AnalysisFrame(inputLeft: 0, inputRight: 0, outputLeft: 0, outputRight: 0),
319 |         count: Self.drainCapacity
    |                `- error: covariant 'Self' type cannot be referenced from a stored property initializer
```

```text
329 |     private var latestOutput = [Float](repeating: 0, count: Self.historyCapacity)
330 |     private var latestLeft = [Float](repeating: 0, count: Self.correlationCapacity)
    |                                                           `- error: covariant 'Self' type cannot be referenced from a stored property initializer
331 |     private var latestRight = [Float](repeating: 0, count: Self.correlationCapacity)
332 | 


```

