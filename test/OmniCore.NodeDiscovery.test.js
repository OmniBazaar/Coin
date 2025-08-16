const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * Tests for OmniCore Node Discovery Registry
 * 
 * Tests the decentralized node discovery system that allows validators
 * to register their HTTP endpoints without expensive heartbeat transactions.
 */
describe('OmniCore - Node Discovery Registry', function () {
    let omniCore;
    let omniCoin;
    let admin;
    let gateway1;
    let gateway2;
    let computation1;
    let listing1;
    let listing2;
    let user;
    let oddao;
    let stakingPool;

    const GATEWAY_TYPE = 0;
    const COMPUTATION_TYPE = 1;
    const LISTING_TYPE = 2;

    beforeEach(async function () {
        [admin, gateway1, gateway2, computation1, listing1, listing2, user, oddao, stakingPool] = 
            await ethers.getSigners();

        // Deploy OmniCoin
        const OmniCoinFactory = await ethers.getContractFactory('OmniCoin');
        omniCoin = await OmniCoinFactory.deploy();
        await omniCoin.waitForDeployment();
        
        // Initialize OmniCoin
        await omniCoin.connect(admin).initialize();

        // Deploy OmniCore
        const OmniCoreFactory = await ethers.getContractFactory('OmniCore');
        omniCore = await OmniCoreFactory.deploy(
            admin.address,
            await omniCoin.getAddress(),
            oddao.address,
            stakingPool.address
        );
        await omniCore.waitForDeployment();
    });

    describe('Node Registration', function () {
        it('should allow nodes to register themselves', async function () {
            const httpEndpoint = 'https://gateway1.omnibazaar.com';
            const wsEndpoint = 'wss://gateway1.omnibazaar.com';
            const region = 'US';

            await expect(
                omniCore.connect(gateway1).registerNode(
                    httpEndpoint,
                    wsEndpoint,
                    region,
                    GATEWAY_TYPE
                )
            ).to.emit(omniCore, 'NodeRegistered')
             .withArgs(gateway1.address, GATEWAY_TYPE, httpEndpoint, true);

            // Verify node info
            const info = await omniCore.getNodeInfo(gateway1.address);
            expect(info.httpEndpoint).to.equal(httpEndpoint);
            expect(info.wsEndpoint).to.equal(wsEndpoint);
            expect(info.region).to.equal(region);
            expect(info.nodeType).to.equal(GATEWAY_TYPE);
            expect(info.active).to.be.true;
            expect(info.lastUpdate).to.be.gt(0);
        });

        it('should update node info on re-registration', async function () {
            // First registration
            await omniCore.connect(listing1).registerNode(
                'https://listing1.omnibazaar.com',
                '',
                'EU',
                LISTING_TYPE
            );

            // Update registration
            const newEndpoint = 'https://listing1-new.omnibazaar.com';
            await omniCore.connect(listing1).registerNode(
                newEndpoint,
                'wss://listing1-new.omnibazaar.com',
                'US', // Changed region
                LISTING_TYPE
            );

            const info = await omniCore.getNodeInfo(listing1.address);
            expect(info.httpEndpoint).to.equal(newEndpoint);
            expect(info.region).to.equal('US');
        });

        it('should reject invalid node types', async function () {
            await expect(
                omniCore.connect(user).registerNode(
                    'https://invalid.com',
                    '',
                    'US',
                    3 // Invalid type
                )
            ).to.be.revertedWithCustomError(omniCore, 'InvalidAmount');
        });

        it('should reject empty HTTP endpoints', async function () {
            await expect(
                omniCore.connect(user).registerNode(
                    '',
                    'wss://test.com',
                    'US',
                    LISTING_TYPE
                )
            ).to.be.revertedWithCustomError(omniCore, 'InvalidAddress');
        });

        it('should track active node counts correctly', async function () {
            expect(await omniCore.getActiveNodeCount(GATEWAY_TYPE)).to.equal(0);
            expect(await omniCore.getActiveNodeCount(LISTING_TYPE)).to.equal(0);

            // Register gateway
            await omniCore.connect(gateway1).registerNode(
                'https://gateway1.com',
                '',
                'US',
                GATEWAY_TYPE
            );
            expect(await omniCore.getActiveNodeCount(GATEWAY_TYPE)).to.equal(1);

            // Register listings
            await omniCore.connect(listing1).registerNode(
                'https://listing1.com',
                '',
                'EU',
                LISTING_TYPE
            );
            await omniCore.connect(listing2).registerNode(
                'https://listing2.com',
                '',
                'ASIA',
                LISTING_TYPE
            );
            expect(await omniCore.getActiveNodeCount(LISTING_TYPE)).to.equal(2);
        });
    });

    describe('Node Deactivation', function () {
        beforeEach(async function () {
            // Register some nodes
            await omniCore.connect(gateway1).registerNode(
                'https://gateway1.omnibazaar.com',
                '',
                'US',
                GATEWAY_TYPE
            );
            await omniCore.connect(listing1).registerNode(
                'https://listing1.omnibazaar.com',
                '',
                'EU',
                LISTING_TYPE
            );
        });

        it('should allow nodes to self-deactivate', async function () {
            await expect(
                omniCore.connect(gateway1).deactivateNode('Maintenance')
            ).to.emit(omniCore, 'NodeDeactivated')
             .withArgs(gateway1.address, 'Maintenance');

            const info = await omniCore.getNodeInfo(gateway1.address);
            expect(info.active).to.be.false;

            // Active count should decrease
            expect(await omniCore.getActiveNodeCount(GATEWAY_TYPE)).to.equal(0);
        });

        it('should allow admin to force-deactivate nodes', async function () {
            await expect(
                omniCore.connect(admin).adminDeactivateNode(
                    listing1.address,
                    'Policy violation'
                )
            ).to.emit(omniCore, 'NodeDeactivated')
             .withArgs(listing1.address, 'Policy violation');

            const info = await omniCore.getNodeInfo(listing1.address);
            expect(info.active).to.be.false;
        });

        it('should reject deactivation of already inactive nodes', async function () {
            await omniCore.connect(gateway1).deactivateNode('Test');
            
            await expect(
                omniCore.connect(gateway1).deactivateNode('Test again')
            ).to.be.revertedWithCustomError(omniCore, 'InvalidAddress');
        });

        it('should reject admin deactivation by non-admin', async function () {
            await expect(
                omniCore.connect(user).adminDeactivateNode(
                    gateway1.address,
                    'Unauthorized'
                )
            ).to.be.revertedWithCustomError(omniCore, 'AccessControlUnauthorizedAccount');
        });
    });

    describe('Node Re-registration', function () {
        it('should allow deactivated nodes to re-register', async function () {
            // Register
            await omniCore.connect(gateway1).registerNode(
                'https://gateway1.omnibazaar.com',
                '',
                'US',
                GATEWAY_TYPE
            );
            
            // Deactivate
            await omniCore.connect(gateway1).deactivateNode('Going offline');
            expect(await omniCore.getActiveNodeCount(GATEWAY_TYPE)).to.equal(0);

            // Re-register (simulating gateway restart)
            await omniCore.connect(gateway1).registerNode(
                'https://gateway1-new.omnibazaar.com',
                '',
                'US',
                GATEWAY_TYPE
            );

            const info = await omniCore.getNodeInfo(gateway1.address);
            expect(info.active).to.be.true;
            expect(info.httpEndpoint).to.equal('https://gateway1-new.omnibazaar.com');
            expect(await omniCore.getActiveNodeCount(GATEWAY_TYPE)).to.equal(1);
        });

        it('should maintain node array correctly on re-registration', async function () {
            // Register multiple nodes
            await omniCore.connect(gateway1).registerNode('https://g1.com', '', 'US', GATEWAY_TYPE);
            await omniCore.connect(gateway2).registerNode('https://g2.com', '', 'EU', GATEWAY_TYPE);
            
            expect(await omniCore.getTotalNodeCount()).to.equal(2);

            // Deactivate and re-register
            await omniCore.connect(gateway1).deactivateNode('Restart');
            await omniCore.connect(gateway1).registerNode('https://g1-new.com', '', 'US', GATEWAY_TYPE);

            // Should not add duplicate entries
            expect(await omniCore.getTotalNodeCount()).to.equal(2);
        });
    });

    describe('Node Discovery', function () {
        beforeEach(async function () {
            // Register various nodes
            await omniCore.connect(gateway1).registerNode('https://g1.com', '', 'US', GATEWAY_TYPE);
            await omniCore.connect(gateway2).registerNode('https://g2.com', '', 'EU', GATEWAY_TYPE);
            await omniCore.connect(computation1).registerNode('https://c1.com', '', 'US', COMPUTATION_TYPE);
            await omniCore.connect(listing1).registerNode('https://l1.com', '', 'ASIA', LISTING_TYPE);
            await omniCore.connect(listing2).registerNode('https://l2.com', '', 'US', LISTING_TYPE);
        });

        it('should return active nodes by type', async function () {
            const gateways = await omniCore.getActiveNodes(GATEWAY_TYPE, 10);
            expect(gateways.length).to.equal(2);
            expect(gateways).to.include(gateway1.address);
            expect(gateways).to.include(gateway2.address);

            const listings = await omniCore.getActiveNodes(LISTING_TYPE, 10);
            expect(listings.length).to.equal(2);
            expect(listings).to.include(listing1.address);
            expect(listings).to.include(listing2.address);
        });

        it('should respect limit parameter', async function () {
            const gateways = await omniCore.getActiveNodes(GATEWAY_TYPE, 1);
            expect(gateways.length).to.equal(1);
        });

        it('should exclude inactive nodes', async function () {
            // Deactivate one gateway
            await omniCore.connect(gateway1).deactivateNode('Maintenance');

            const gateways = await omniCore.getActiveNodes(GATEWAY_TYPE, 10);
            expect(gateways.length).to.equal(1);
            expect(gateways[0]).to.equal(gateway2.address);
        });

        it('should handle empty results gracefully', async function () {
            // Deactivate all gateways
            await omniCore.connect(gateway1).deactivateNode('Test');
            await omniCore.connect(gateway2).deactivateNode('Test');

            const gateways = await omniCore.getActiveNodes(GATEWAY_TYPE, 10);
            expect(gateways.length).to.equal(0);
        });
    });

    describe('Integration with Validator Discovery', function () {
        beforeEach(async function () {
            // Register various nodes for integration tests
            await omniCore.connect(gateway1).registerNode('https://g1.com', '', 'US', GATEWAY_TYPE);
            await omniCore.connect(gateway2).registerNode('https://g2.com', '', 'EU', GATEWAY_TYPE);
            await omniCore.connect(computation1).registerNode('https://c1.com', '', 'US', COMPUTATION_TYPE);
            await omniCore.connect(listing1).registerNode('https://l1.com', '', 'ASIA', LISTING_TYPE);
            await omniCore.connect(listing2).registerNode('https://l2.com', '', 'US', LISTING_TYPE);
        });

        it('should allow validators to query for active gateway nodes', async function () {
            // Register gateways with real-world endpoints
            await omniCore.connect(gateway1).registerNode(
                'https://us-east-1.gateway.omnibazaar.com',
                'wss://us-east-1.gateway.omnibazaar.com',
                'US',
                GATEWAY_TYPE
            );
            await omniCore.connect(gateway2).registerNode(
                'https://eu-west-1.gateway.omnibazaar.com',
                'wss://eu-west-1.gateway.omnibazaar.com',
                'EU',
                GATEWAY_TYPE
            );

            // Query for gateways
            const gateways = await omniCore.getActiveNodes(GATEWAY_TYPE, 10);
            
            // Validator can iterate through and get details
            for (const gateway of gateways) {
                const info = await omniCore.getNodeInfo(gateway);
                expect(info.httpEndpoint).to.include('.gateway.omnibazaar.com');
                expect(info.active).to.be.true;
            }
        });

        it('should provide total counts for network statistics', async function () {
            expect(await omniCore.getTotalNodeCount()).to.equal(5);
            expect(await omniCore.getActiveNodeCount(GATEWAY_TYPE)).to.equal(2);
            expect(await omniCore.getActiveNodeCount(COMPUTATION_TYPE)).to.equal(1);
            expect(await omniCore.getActiveNodeCount(LISTING_TYPE)).to.equal(2);
        });
    });

    describe('Edge Cases', function () {
        it('should handle node type boundary correctly', async function () {
            await expect(
                omniCore.getActiveNodeCount(3)
            ).to.be.revertedWithCustomError(omniCore, 'InvalidAmount');

            await expect(
                omniCore.getActiveNodes(3, 10)
            ).to.be.revertedWithCustomError(omniCore, 'InvalidAmount');
        });

        it('should handle zero limit gracefully', async function () {
            await omniCore.connect(gateway1).registerNode('https://g1.com', '', 'US', GATEWAY_TYPE);
            
            const nodes = await omniCore.getActiveNodes(GATEWAY_TYPE, 0);
            expect(nodes.length).to.equal(0);
        });

        it('should handle WebSocket-only nodes', async function () {
            await omniCore.connect(listing1).registerNode(
                'https://listing1.com',
                '', // No WebSocket endpoint
                'US',
                LISTING_TYPE
            );

            const info = await omniCore.getNodeInfo(listing1.address);
            expect(info.wsEndpoint).to.equal('');
        });
    });
});