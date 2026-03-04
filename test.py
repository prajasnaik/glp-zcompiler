def fib(n: int):
    stack = [(n, 0, None, None)]  # (n, stage, left_result, right_result)
    result_stack = []
    
    while stack:
        n, stage, left_result, right_result = stack.pop()
        
        if n <= 1:
            result_stack.append(n)
        elif stage == 0:
            # First time seeing this call, push it back and compute fib(n-1)
            stack.append((n, 1, None, None))
            stack.append((n - 1, 0, None, None))
        elif stage == 1:
            # Returned from fib(n-1), now compute fib(n-2)
            left_result = result_stack.pop()
            stack.append((n, 2, left_result, None))
            stack.append((n - 2, 0, None, None))
        else:  # stage == 2
            # Returned from fib(n-2), combine results
            right_result = result_stack.pop()
            result_stack.append(left_result + right_result)
    
    return result_stack[0]

print(fib(10))