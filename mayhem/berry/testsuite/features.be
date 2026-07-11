# Deterministic Berry seed exercising several language paths: integer/real math, control flow,
# a recursive function, lists, maps, ranges, a class with a method, and string formatting.
def fib(n)
    if n <= 2 return 1 end
    return fib(n - 1) + fib(n - 2)
end

var total = 0
for i : 1..10
    total += fib(i)
end
print("fib sum:", total)

var nums = [3, 1, 4, 1, 5, 9, 2, 6]
var sum = 0
for n : nums
    sum += n
end
print("list sum:", sum)

var m = {"a": 1, "b": 2, "c": 3}
m["d"] = m["a"] + m["b"] + m["c"]
print("map d:", m["d"])

class Point
    var x, y
    def init(x, y)
        self.x = x
        self.y = y
    end
    def norm2()
        return self.x * self.x + self.y * self.y
    end
end
var p = Point(3, 4)
print("norm2:", p.norm2())

print(format("%d %s %.2f", 42, "ok", 3.14159))
