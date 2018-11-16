"""

Script to generate topology.txt automatically on any given grid size

"""

def findNeighbourhood(grid, j, D, radio):

    neighbourhood = []
    row = j/D
    col = j%D

    for x in range(D):
        for y in range(D):
            if x != row or y!=col:
                dist = ((abs(x-row)**2) + (abs(y - col)**2)) ** 0.5
            else:
                dist = 0

            if 0 < dist <= radio:
                neighbourhood.append(grid[x][y])

    return neighbourhood

def findTopology(D , radio):
    # Create grid
    grid = [[x + y*D for x in range(D)] for y in range(D)]

    file = open('topology.txt', 'w')
    file.truncate()
    for j in range(D**2):
        neighbours = findNeighbourhood(grid, j, D, radio)
        print("node's %d neighbours: " % j)
        print(neighbours)
        for i in range(len(neighbours)):
            file.write("%s %s -50.0\n" % (grid[j/D][j%D], neighbours[i]))
        file.write('\n')

    file.close()





if __name__ == '__main__':
    try:
        D = int(input("Give me grid size (max 8): "))
        radio = float(input("Give me grid range: "))
    except:
        D = 8
        radio = 1

    findTopology(D, radio)


