"""

Script to generate topology.txt automatically on any given grid size

"""

# find j node's neighbours for grid size D and range rng
def findNeighbourhood(grid, j, D, rng):

    # array holding j's neighbours
    neighbourhood = []

    # find j's position in grid (row,col)
    row = j/D
    col = j%D

    # find j's distance from each node in the grid
    for x in range(D):
        for y in range(D):
            # j's distance from node (x,y)
            dist = ((abs(x-row)**2) + (abs(y - col)**2)) ** 0.5

            # if distance is within j's range, we have a new neighbour!
            if 0 < dist <= rng:
                neighbourhood.append(grid[x][y])

    # return j's neighbours
    return neighbourhood

def findTopology(D , rng):
    # Create and fill grid
    grid = [[x + y*D for x in range(D)] for y in range(D)]

    # configure topology.txt
    file = open('topology.txt', 'w')
    file.truncate()

    # Find each node's neighbours
    for j in range(D**2):
        neighbours = findNeighbourhood(grid, j, D, rng)
        print("node's %d neighbours: " % j)
        print(neighbours)

        # append connected nodes in topology.txt
        for i in range(len(neighbours)):
            file.write("%s %s -50.0\n" % (grid[j/D][j%D], neighbours[i]))
        file.write('\n')

    file.close()

# MAIN
if __name__ == '__main__':
    # Wait for input on grid size and range
    D = 9
    try:
        while not D <= 8 : D = int(input("Give me grid size (max 8): "))
        rng = float(input("Give me grid range: "))
    # error
    except:
        D = 8
        rng = 1

    findTopology(D, rng)
