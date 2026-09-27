
original:
```swift
public enum ShaderArgument: Hashable, Sendable {
    case float(String, Double)
    case float2(String, Double, Double)
    case float3(String, Double, Double, Double)
    case float4(String, Double, Double, Double, Double)
    case color(String, Color)
    case floatArray(String, [Float])

}
```


new: 

```swift

public struct Float2 {
    var v1: Float
    var v2: Float
}

public struct Float3 {
    var v1: Float
    var v2: Float
    var v3: Float
}

public struct Float4 {
    var v1: Float
    var v2: Float
    var v3: Float
    var v4: Float
}
```

```swift
public enum ShaderArgument: Hashable, Sendable {
    case float(String, Float)
    case float2(String, Float2)
    case float3(String, Float3)
    case float4(String, Float4)
    case color(String, Color)
    case floatArray(String, [Float])
    case float2Array(String, [Float2])
    case float3Array(String, [Float3])
    case float4Array(String, [Float4])

}
```