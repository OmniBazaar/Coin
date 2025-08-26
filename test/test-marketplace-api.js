const axios = require('axios');

async function testMarketplaceAPI() {
  try {
    const listing = {
      title: 'Test Product',
      description: 'Testing marketplace API',
      price: '1000000000000000000', // 1 XOM in wei
      category: 'electronics',
      images: ['QmTestImageCID'],
      seller: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'
    };

    console.log('Creating listing...');
    const response = await axios.post('http://localhost:8090/api/marketplace/listings', listing);
    console.log('Success:', response.data);
  } catch (error) {
    console.error('Error:', error.response?.data || error.message);
    if (error.response?.data) {
      console.error('Response:', JSON.stringify(error.response.data, null, 2));
    }
  }
}

testMarketplaceAPI();