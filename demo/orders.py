def total(prices, tax):
    result = 0
    for price in prices:
        result = result + price * (1 + tax)
    return result


def average(values):
    if len(values) == 0:
        return 0
    return sum(values) / len(values)


def greet(user):
    print("hey " + user.name + " ur order is rdy")
